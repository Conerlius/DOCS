-----------------------------------------------
-- import函数将代替默认的require
-- 使用方法：module = Import("something.lua")
--
-- 编程约束：
-- (1)module区分为两种 1. 纯实现module  2.纯数据module
-- (2)实现module的非函数局部层级不要写赋值语句，和调用函数
--    实现module会触发SafeImport(isReload=true)的更新，递归替换逐级保持table指针有效性
-- (3)数据module只需要重新执行dofile暴力更新
-- (4)【非必要】不要在非函数局部层级写引用的持有语句，比如self._ref = ReadOnlyData.Attribute.ConfigDict.v
--    因为会使得纯数据module的热更变得复杂
-----------------------------------------------



-- 全局缓存已经加载的模块
_G.ImportedModules = _G.ImportedModules or {}
local ImportedModules = _G.ImportedModules


-- 模拟Lua5.1的setfenv
local function setfenv(fn, env)
  local i = 1
  while true do
    local name = debug.getupvalue(fn, i)
    if name == "_ENV" then
      debug.upvaluejoin(fn, i, (function()
        return env
      end), 1)
      break
    elseif not name then
      break
    end

    i = i + 1
  end

  return fn
end


-- 将src table的引用递归替换到dest table
-- 目的是保持dest地址的引用的【递归前置引用】的有效性
local function ReplaceTableRefs(dest, src)
    
    local function _RealFunc(dest, src, depth)
        assert(type(dest) == "table" and type(src) == "table", "dest/src must be table type")
        if not depth then
            depth = 0
           end
        if depth >= 30 then
            error("too deeeeep")
            return
        end

        for k, v in pairs(dest) do
            if type(v) == "table" then
                -- 不对__index (继承关系)table做处理
                if type(src[k]) == "table" and k ~= "__index" then
                    _RealFunc(v, src[k], depth+1)
                else -- 非table，即为function, const等类型，直接使用新对象即可
                    dest[k] = src[k]
                end
            else
                dest[k] = src[k]
            end
        end

        -- src新增的k/v加入到dest
        for k, v in pairs(src) do
            -- 使用rawget来【防止】dest访问matatable来获取父类的k对应是否存在v，从而导致子类添加k/v无效
            if rawget(dest, k) == nil then
                dest[k] = v
            end
        end
    end

    _RealFunc(dest, src)
end


------------------------------------------
-- import和reload于一体的函数
--
-- 热更新的关键处理步骤为：
-- (1)
--
------------------------------------------
local function SafeImport(filePath, isReload)
    local old = ImportedModules[filePath]
    if old and not isReload then
        return old
    end

    local func, err = loadfile(filePath)
    if not func then
        return nil, err
    end

    -- [全新加载]
    -- 为新加载的模块设置全新配置
    if not old then
        local new = {}
        ImportedModules[filePath] = new

        setmetatable(new, {__index = _G})
        setfenv(func, new)()

        -- 若新模块有初始，调用自定初始函数
        if new.__INIT__ then
            new:__INIT__()
        end

        return new
    end

    -- 若旧模块有结尾函数，调用自定结尾函数
    if old.__DESTROY__ then
        old:__DESTROY__()
    end


    -- 备份到新table，并删除old module中的k/v，但保留old module是同一个table提供给后续的updated
    local oldCache = {}
    for k, v in pairs(old) do
        oldCache[k] = v
        old[k] = nil
    end

    -- [热更新]
    -- 将新module的func code在old module的空间内执行，
    -- 覆盖k/v为新的实现和新的数据引用(所以旧的引用在此刻是暂时失效，接下来马上处理)
    setfenv(func, old)()

    -- 将clear掉k/v的old视为new（保持了old module引用不变）
    local new = old

    -- 针对old在执行SafeImport前原来已有的k/v, 做引用处理
    for k, oldV in pairs(oldCache) do
        -- 全新的v定义
        local newV = new[k]
        -- 旧有的v定义
        new[k] = oldV
    
        -- 执行SafeImport前old中的k，new中现在也有，那么执行引用处理；
        -- 否则证明new中新的写法里面已经没有这个k，就不管
        if newV then
            
            if type(oldV) == "function" then -- 第一层就是函数体，使用全新定义即可
                new[k] = newV
            elseif type(oldV) == "table" then -- table，分为class/object table， 和pure data table两种情况
                -- class/object table(拥有IsClass函数并返回true的table)，需要全部递归更新k/v
                if oldV.IsClass and oldV:IsClass() then
                    -- 将newV中的k/v递归替换到oldV, 目的是保持oldV address若热更前被引用，还能继续有效
                    ReplaceTableRefs(oldV, newV)
                end

                -- 替换metatable
                local mt = getmetatable(newV)
                if mt then
                    setmetatable(oldV, mt)
                end
            end
        
            -- !!!!!!!  其他类型，不予更新  !!!!!!!
        end
    end

    -- 若新模块有初始定义，调用自定初始函数
    if new.__INIT__ then
        new:__INIT__()
    end

    -- 若新模块有更新定义，调用自定更新函数
    if new.__UPDATE__ then
        new:__UPDATE__()
    end


    return new
end


function Import(filePath)
    local module, err = SafeImport(filePath, false)
    assert(module, err)
    return module
end


local DATAMODULE_MAP = {["data1.lua"]=true, ["data2.lua"]=true}
function Update(filePath)
    -- 数据module
    if DATAMODULE_MAP[filePath] then
        dofile(filePath)
        return true, "no error"
    else -- 实现module
        local module, err = SafeImport(filePath, true)
        if module == nil then
            return false, err
        end
        return true, "no error"
    end
end
