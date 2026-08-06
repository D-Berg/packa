---Wraps `native` functions so they can safely return
--- errors and defer with longjump after cleanup
---@param native fun(...: any): (any, string?)
---@return fun(...: any): any
return function(native)
    return function(...)
        local value, failure = native(...)
        if failure ~= nil then
            error(failure, 2)
        end
        return value
    end
end
