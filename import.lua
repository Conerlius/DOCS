-----------------------------------------------
-- import����������Ĭ�ϵ�require
-- ʹ�÷�����module = Import("something.lua")
--
-- ���Լ����
-- (1)module����Ϊ���� 1. ��ʵ��module  2.������module
-- (2)ʵ��module�ķǺ����ֲ��㼶��Ҫд��ֵ��䣬�͵��ú���
--    ʵ��module�ᴥ��SafeImport(isReload=true)�ĸ��£��ݹ��滻�𼶱���tableָ����Ч��
-- (3)����moduleֻ��Ҫ����ִ��dofile��������
-- (4)���Ǳ�Ҫ����Ҫ�ڷǺ����ֲ��㼶д���õĳ�����䣬����self._ref = ReadOnlyData.Attribute.ConfigDict.v
--    ��Ϊ��ʹ�ô�����module���ȸ���ø���
-----------------------------------------------



-- ȫ�ֻ����Ѿ����ص�ģ��
_G.ImportedModules = _G.ImportedModules or {}
local ImportedModules = _G.ImportedModules


-- ģ��Lua5.1��setfenv
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


-- ��src table�����õݹ��滻��dest table
-- Ŀ���Ǳ���dest��ַ�����õġ��ݹ�ǰ�����á�����Ч��
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
                -- ����__index (�̳й�ϵ)table������
                if type(src[k]) == "table" and k ~= "__index" then
                    _RealFunc(v, src[k], depth+1)
                else -- ��table����Ϊfunction, const�����ͣ�ֱ��ʹ���¶��󼴿�
                    dest[k] = src[k]
                end
            else
                dest[k] = src[k]
            end
        end

        -- src������k/v���뵽dest
        for k, v in pairs(src) do
            -- ʹ��rawget������ֹ��dest����matatable����ȡ�����k��Ӧ�Ƿ����v���Ӷ������������k/v��Ч
            if rawget(dest, k) == nil then
                dest[k] = v
            end
        end
    end

    _RealFunc(dest, src)
end


------------------------------------------
-- import��reload��һ��ĺ���
--
-- �ȸ��µĹؼ�������Ϊ��
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

    -- [ȫ�¼���]
    -- Ϊ�¼��ص�ģ������ȫ������
    if not old then
        local new = {}
        ImportedModules[filePath] = new

        setmetatable(new, {__index = _G})
        setfenv(func, new)()

        -- ����ģ���г�ʼ�������Զ���ʼ����
        if new.__INIT__ then
            new:__INIT__()
        end

        return new
    end

    -- ����ģ���н�β�����������Զ���β����
    if old.__DESTROY__ then
        old:__DESTROY__()
    end


    -- ���ݵ���table����ɾ��old module�е�k/v��������old module��ͬһ��table�ṩ��������updated
    local oldCache = {}
    for k, v in pairs(old) do
        oldCache[k] = v
        old[k] = nil
    end

    -- [�ȸ���]
    -- ����module��func code��old module�Ŀռ���ִ�У�
    -- ����k/vΪ�µ�ʵ�ֺ��µ���������(���Ծɵ������ڴ˿�����ʱʧЧ�����������ϴ���)
    setfenv(func, old)()

    -- ��clear��k/v��old��Ϊnew��������old module���ò��䣩
    local new = old

    -- ���old��ִ��SafeImportǰԭ�����е�k/v, �����ô���
    for k, oldV in pairs(oldCache) do
        -- ȫ�µ�v����
        local newV = new[k]
        -- ���е�v����
        new[k] = oldV
    
        -- ִ��SafeImportǰold�е�k��new������Ҳ�У���ôִ�����ô���
        -- ����֤��new���µ�д�������Ѿ�û�����k���Ͳ���
        if newV then
            
            if type(oldV) == "function" then -- ��һ����Ǻ����壬ʹ��ȫ�¶��弴��
                new[k] = newV
            elseif type(oldV) == "table" then -- table����Ϊclass/object table�� ��pure data table�������
                -- class/object table(ӵ��IsClass����������true��table)����Ҫȫ���ݹ����k/v
                if oldV.IsClass and oldV:IsClass() then
                    -- ��newV�е�k/v�ݹ��滻��oldV, Ŀ���Ǳ���oldV address���ȸ�ǰ�����ã����ܼ�����Ч
                    ReplaceTableRefs(oldV, newV)
                end

                -- �滻metatable
                local mt = getmetatable(newV)
                if mt then
                    setmetatable(oldV, mt)
                end
            end
        
            -- !!!!!!!  �������ͣ��������  !!!!!!!
        end
    end

    -- ����ģ���г�ʼ���壬�����Զ���ʼ����
    if new.__INIT__ then
        new:__INIT__()
    end

    -- ����ģ���и��¶��壬�����Զ����º���
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
    -- ����module
    if DATAMODULE_MAP[filePath] then
        dofile(filePath)
        return true, "no error"
    else -- ʵ��module
        local module, err = SafeImport(filePath, true)
        if module == nil then
            return false, err
        end
        return true, "no error"
    end
end
