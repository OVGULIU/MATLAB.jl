# operation on MATLAB engine sessions

###########################################################
#
#   Session open & close
#
###########################################################

# 64 K buffer should be sufficient to store the output text in most cases
const default_output_buffer_size = 64 * 1024

type MSession
    ptr::Ptr{Void}
    buffer::Vector{UInt8}
    bufptr::Ptr{UInt8}

    function MSession(bufsize::Integer = default_output_buffer_size)
        global libeng
        libeng == C_NULL && load_libeng()
        @assert libeng != C_NULL

        ep = ccall(engfunc(:engOpen), Ptr{Void}, (Ptr{UInt8},), default_startcmd)
        ep == C_NULL && throw(MEngineError("Failed to open a MATLAB engine session."))

        buf = Array(UInt8, bufsize)

        if bufsize > 0
            bufptr = pointer(buf)
            ccall(engfunc(:engOutputBuffer), Cint, (Ptr{Void}, Ptr{UInt8}, Cint),
                ep, bufptr, bufsize)
        else
            bufptr = convert(Ptr{UInt8}, C_NULL)
        end
        
        if is_windows()
            # Hide the MATLAB Command Window on Windows
            ccall(engfunc(:engSetVisible ), Cint, (Ptr{Void}, Cint), ep, 0)
        end
        self = new(ep, buf, bufptr)
        finalizer(self, release)
        return self
    end
end

function unsafe_convert(::Type{Ptr{Void}}, m::MSession)
    ptr = m.ptr
    ptr == C_NULL && throw(UndefRefError())
    return ptr
end

function release(session::MSession)
    ptr = session.ptr
    if ptr != C_NULL
        ccall(engfunc(:engClose), Cint, (Ptr{Void},), ptr)
    end
    session.ptr = C_NULL
    return nothing
end

function close(session::MSession)
    # Close a MATLAB Engine session
    @assert libeng::Ptr{Void} != C_NULL
    ret = ccall(engfunc(:engClose), Cint, (Ptr{Void},), session)
    ret != 0 && throw(MEngineError("Failed to close a MATLAB engine session (err = $r)"))
    session.ptr = C_NULL
    return nothing
end

# default session

default_msession = nothing

function restart_default_msession(bufsize::Integer = default_output_buffer_size)
    global default_msession
    if default_msession !== nothing && default_msession.ptr != C_NULL
        close(default_msession)
    end
    default_msession = MSession(bufsize)
    return nothing
end


function get_default_msession()
    global default_msession
    if default_msession === nothing
        default_msession = MSession()
    end
    return default_msession::MSession
end

function close_default_msession()
    global default_msession
    if default_msession !== nothing
        close(default_msession)
        default_msession = nothing
    end
    return nothing
end


###########################################################
#
#   communication with MATLAB session
#
###########################################################

function eval_string(session::MSession, stmt::String)
    # Evaluate a MATLAB statement in a given MATLAB session
    @assert libeng::Ptr{Void} != C_NULL

    r = ccall(engfunc(:engEvalString), Cint, (Ptr{Void}, Ptr{UInt8}), session, stmt)
    r != 0 && throw(MEngineError("Invalid engine session."))

    bufptr::Ptr{UInt8} = session.bufptr
    if bufptr != C_NULL
        bs = unsafe_string(bufptr)
        if ~isempty(bs)
            print(bs)
        end
    end
end

eval_string(stmt::String) = eval_string(get_default_msession(), stmt)


function put_variable(session::MSession, name::Symbol, v::MxArray)
    # Put a variable into a MATLAB engine session
    @assert libeng::Ptr{Void} != C_NULL
    r = ccall(engfunc(:engPutVariable), Cint, (Ptr{Void}, Ptr{UInt8}, Ptr{Void}), session, string(name), v)
    r != 0 && throw(MEngineError("Failed to put the variable $(name) into a MATLAB session."))
    return nothing
end

put_variable(session::MSession, name::Symbol, v) = put_variable(session, name, mxarray(v))

put_variable(name::Symbol, v) = put_variable(get_default_msession(), name, v)


function get_mvariable(session::MSession, name::Symbol)

    @assert libeng::Ptr{Void} != C_NULL

    pv = ccall(engfunc(:engGetVariable), Ptr{Void},
        (Ptr{Void}, Ptr{UInt8}), session, string(name))

    if pv == C_NULL
        throw(MEngineError("Failed to get the variable $(name) from a MATLAB session."))
    end
    MxArray(pv)
end

get_mvariable(name::Symbol) = get_mvariable(get_default_msession(), name)

get_variable(name::Symbol) = jvalue(get_mvariable(name))
get_variable(name::Symbol, kind) = jvalue(get_mvariable(name), kind)


###########################################################
#
#   macro to simplify syntax
#
###########################################################

function _mput_multi(vs::Symbol...)
    nv = length(vs)
    if nv == 1
        v = vs[1]
        :( MATLAB.put_variable($(Meta.quot(v)), $(v)) )
    else
        stmts = Array(Expr, nv)
        for i = 1 : nv
            v = vs[i]
            stmts[i] = :( MATLAB.put_variable($(Meta.quot(v)), $(v)) )
        end
        Expr(:block, stmts...)
    end
end

macro mput(vs...)
    esc( _mput_multi(vs...) )
end


function make_getvar_statement(v::Symbol)
    :( $(v) = MATLAB.get_variable($(Meta.quot(v))) )
end

function make_getvar_statement(ex::Expr)
    if !(ex.head == :(::))
        error("Invalid expression for @mget.")
    end
    v::Symbol = ex.args[1]
    k::Symbol = ex.args[2]
    
    :( $(v) = MATLAB.get_variable($(Meta.quot(v)), $(k)) )
end

function _mget_multi(vs::Union{Symbol, Expr}...)
    nv = length(vs)
    if nv == 1
        make_getvar_statement(vs[1])
    else
        stmts = Array(Expr, nv)
        for i = 1:nv
            stmts[i] = make_getvar_statement(vs[i])
        end
        Expr(:block, stmts...)
    end
end

macro mget(vs...)
    esc( _mget_multi(vs...) )
end

macro matlab(ex)
    :( MATLAB.eval_string($(mstatement(ex))) )
end


###########################################################
#
#   mxcall
#
###########################################################

# MATLAB does not allow underscore as prefix of a variable name
_gen_marg_name(mfun::Symbol, prefix::String, i::Int) = "jx_$(mfun)_arg_$(prefix)_$(i)"
 
function mxcall(session::MSession, mfun::Symbol, nout::Integer, in_args...)
    nin = length(in_args)
    
    # generate temporary variable names
    
    in_arg_names = Array(String, nin)
    out_arg_names = Array(String, nout)
     
    for i = 1:nin
        in_arg_names[i] = _gen_marg_name(mfun, "in", i)
    end
    
    for i = 1:nout
        out_arg_names[i] = _gen_marg_name(mfun, "out", i)
    end
    
    # generate MATLAB statement
    
    buf = IOBuffer()
    if nout > 0
        if nout > 1
            print(buf, "[")
        end
        join(buf, out_arg_names, ", ")
        if nout > 1
            print(buf, "]")
        end
        print(buf, " = ")
    end
    
    print(buf, string(mfun))
    print(buf, "(")
    if nin > 0
        join(buf, in_arg_names, ", ")
    end
    print(buf, ");")
    
    stmt = takebuf_string(buf)
    
    # put variables to MATLAB
    
    for i = 1:nin
        put_variable(session, Symbol(in_arg_names[i]), in_args[i])
    end
    
    # execute MATLAB statement
    
    eval_string(session, stmt)
    
    # get results from MATLAB
    
    ret = if nout == 1
        jvalue(get_mvariable(session, Symbol(out_arg_names[1])))
    elseif nout >= 2
        results = Array(Any, nout)
        for i = 1 : nout
            results[i] = jvalue(get_mvariable(session, Symbol(out_arg_names[i])))
        end
        tuple(results...)
    else
        nothing
    end
    
    # clear temporaries from MATLAB workspace
    
    for i = 1:nin
        eval_string(session, string("clear ", in_arg_names[i], ";"))
    end
    
    for i = 1:nout
        eval_string(session, string("clear ", out_arg_names[i], ";"))
    end
    
    return ret
end

mxcall(mfun::Symbol, nout::Integer, in_args...) = mxcall(get_default_msession(), mfun, nout, in_args...)


