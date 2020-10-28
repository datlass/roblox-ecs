
-- Services
local RunService = game:GetService('RunService')

--[[
  @TODO
      - Table pool (avoid GC)
      - System readonly? Paralel execution
      - Debugging?
      - Benchmark (Local Script vs ECS implementation)
      - Basic physics (managed)
      - SharedComponent?
]]

local function NOW()
	return DateTime.now().UnixTimestampMillis
end

local PRINT_LIMIT_LAST_TIME = {}
local PRINT_LIMIT_COUNT = {}
local function debugF(message)
   local t =  PRINT_LIMIT_LAST_TIME[message]
   if t ~= nil then
      if (t + 1000) < NOW() then
         print(PRINT_LIMIT_COUNT[message],' times > ', message)
         PRINT_LIMIT_LAST_TIME[message] = NOW()
         PRINT_LIMIT_COUNT[message] = 0
         return
      end
      PRINT_LIMIT_COUNT[message] =  PRINT_LIMIT_COUNT[message] + 1
   else
      PRINT_LIMIT_LAST_TIME[message] = NOW()
      PRINT_LIMIT_COUNT[message] = 1
   end
end

-- precision
local EPSILON = 0.000000001

local function floatEQ(n0, n1)
   if n0 == n1 then
      return true
   end

   return math.abs(n1 - n0) < EPSILON
end

local function vectorEQ(v0, v1)
   if v0 == v1 then
      return true
   end

   if not floatEQ(v0.X, v1.X) or not floatEQ(v0.Y, v1.Y) or not floatEQ(v0.Z, v1.Z) then
      return false
   else
      return true
   end
end

-- Ensures values are unique, removes nil values as well
local function safeNumberTable(values)
   if values == nil then
      values = {}
   end

   local hash = {}
	local res  = {}
   for _,v in pairs(values) do
      if v ~= nil and hash[v] == nil then
         table.insert(res, v)
         hash[v] = true
      end
   end
   table.sort(res)
	return res
end

-- generate an identifier for a table that has only numbers
local function hashNumberTable(numbers)
   numbers = safeNumberTable(numbers)
   return '_' .. table.concat(numbers, '_'), numbers
end

--[[
   Global cache result.

   The validated components are always the same (reference in memory, except within the archetypes),
   in this way, you can save the result of a query in an archetype, reducing the overall execution
   time (since we don't need to iterate all the time)

   @Type { [key:Array<number>] : { matchAll,matchAny,rejectAll|rejectAny: {[key:string]:boolean} } }
]]
local FILTER_CACHE_RESULT = {}

--[[
   Generate a function responsible for performing the filter on a list of components.
   It makes use of local and global cache in order to decrease the validation time (avoids looping in runtime of systems)

   Params
      requireAll {Array<number>}
      requireAny {Array<number>}
      rejectAll {Array<number>}
      rejectAny {Array<number>}

   Returns function(Array<number>) => boolean
]]
local function componentFilter(requireAll, requireAny, rejectAll, rejectAny)

   -- local cache (L1)
   local cache = {}

   local requireAllKey, requireAnyKey, rejectAllKey, rejectAnyKey

   requireAllKey, requireAll  = hashNumberTable(requireAll)
   requireAnyKey, requireAny  = hashNumberTable(requireAny)
   rejectAllKey, rejectAll    = hashNumberTable(rejectAll)
   rejectAnyKey, rejectAny    = hashNumberTable(rejectAny)

   -- match function
   return function(components)

      -- check local cache
      local cacheResult = cache[components]
      if cacheResult == false then
         return false

      elseif cacheResult == true then
         return true

      else

         -- check global cache (executed by other filter instance)
         local cacheResultG = FILTER_CACHE_RESULT[components]
         if cacheResultG == nil then
            cacheResultG = { matchAny = {}, matchAll = {}, rejectAny = {}, rejectAll = {} }
            FILTER_CACHE_RESULT[components] = cacheResultG
         end

         -- check if these combinations exist in this component array
         if rejectAnyKey ~= '_' then
            if cacheResultG.rejectAny[rejectAnyKey] or cacheResultG.rejectAll[rejectAnyKey] then
               cache[components] = false
               return false
            end

            for _, v in pairs(rejectAny) do
               if table.find(components, v) then
                  cache[components] = false
                  cacheResultG.matchAny[rejectAnyKey] = true
                  cacheResultG.rejectAny[rejectAnyKey] = true
                  return false
               end
            end
         end

         if rejectAllKey ~= '_' then
            if cacheResultG.rejectAll[rejectAllKey] then
               cache[components] = false
               return false
            end

            local haveAll = true
            for _, v in pairs(rejectAll) do
               if not table.find(components, v) then
                  haveAll = false
                  break
               end
            end

            if haveAll then
               cache[components] = false
               cacheResultG.matchAll[rejectAllKey] = true
               cacheResultG.rejectAll[rejectAllKey] = true
               return false
            end
         end

         if requireAnyKey ~= '_' then
            if cacheResultG.matchAny[requireAnyKey] or cacheResultG.matchAll[requireAnyKey] then
               cache[components] = true
               return true
            end

            for _, v in pairs(requireAny) do
               if table.find(components, v) then
                  cacheResultG.matchAny[requireAnyKey] = true
                  cache[components] = true
                  return true
               end
            end
         end

         if requireAllKey ~= '_' then
            if cacheResultG.matchAll[requireAllKey] then
               cache[components] = true
               return true
            end

            local haveAll = true
            for _, v in pairs(requireAll) do
               if not table.find(components, v) then
                  haveAll = false
                  break
               end
            end

            if haveAll then
               cache[components] = true
               cacheResultG.matchAll[requireAllKey] = true
               cacheResultG.rejectAll[requireAllKey] = true
               return true
            end
         end

         cache[components] = false
         return false
      end
   end
end


----------------------------------------------------------------------------------------------------------------------
-- ARCHETYPE
----------------------------------------------------------------------------------------------------------------------

--[[
    Archetype:
      An entity has an Archetype (defined by the components it has).
      An archetype is an identifier for each unique combination of components. 
      An archetype is singleton
]]
local ARCHETYPES = {}

-- Moment when the last archetype was recorded. Used to cache the systems execution plan
local LAST_ARCHETYPE_INSTANT = NOW()

local Archetype  = {}
Archetype.__index = Archetype

--[[
   Gets the reference to an archetype from the informed components

   Params
      components Array<number> Component IDs that define this archetype
]]
function Archetype.get(components)

   local id

   id, components = hashNumberTable(components)

   if ARCHETYPES[id] == nil then
      ARCHETYPES[id] = setmetatable({
         id          = id,
         components  = components
      }, Archetype)

      LAST_ARCHETYPE_INSTANT = NOW()
   end

   return ARCHETYPES[id]
end

--[[
   Gets the reference to an archetype that has the current components + the informed component
]]
function Archetype:with(component)
   if table.find(self.components, component) ~= nil then
      -- component exists in that list, returns the archetype itself
      return self
   end

   local len = table.getn(self.components)
   local newCoomponents = table.create(len + 1)
   newCoomponents[0] = component
   table.move(self.components, 1, len, 2, newCoomponents)
   return Archetype.get(newCoomponents)
end

--[[
   Gets the reference to an archetype that has the current components - the informed component
]]
function Archetype:without(component)
   if table.find(self.components, component) == nil then
      -- component does not exist in this list, returns the archetype itself
      return self
   end

   local len = table.getn(self.components)
   local newCoomponents = table.create(len - 1)
   local a = 1
   for i = 1, len do
      if self.components[i] ~= component then
         newCoomponents[a] = self.components[i]
         a = a + 1
      end
   end

   return Archetype.get(newCoomponents)
end

-- Generic archetype, for entities that do not have components
local ARCHETYPE_EMPTY = Archetype.get({})

----------------------------------------------------------------------------------------------------------------------
-- COMPONENT
----------------------------------------------------------------------------------------------------------------------
local COMPONENTS_NAME            = {}
local COMPONENTS_CONSTRUCTOR     = {}
local COMPONENTS_IS_TAG          = {}
local COMPONENTS_INDEX_BY_NAME   = {}

local function DEFAULT_CONSTRUCOTR(value)
   return value
end

local Component  = {
   --[[
      Register a new component

      Params:
         name {String} 
            Unique identifier for this component

         constructor {Function}
            Allow you to validate or parse data

         isTag {Boolean}

         @TODO: shared  {Boolean}
            see https://docs.unity3d.com/Packages/com.unity.entities@0.7/manual/shared_component_data.html

      Returns component ID
   ]]
   register = function(name, constructor, isTag) : number

      if name == nil then
         error('Component name is required for registration')
      end

      if constructor ~= nil and type(constructor) ~= 'function' then
         error('The component constructor must be a function, or nil')
      end

      if constructor == nil then
         constructor = DEFAULT_CONSTRUCOTR
      end

      if isTag == nil then
         isTag = false
      end

      if COMPONENTS_INDEX_BY_NAME[name] ~= nil then
         error('Another component already registered with that name')
      end

      -- component type ID = index
      local ID = table.getn(COMPONENTS_NAME) + 1

      COMPONENTS_INDEX_BY_NAME[name] = ID

      table.insert(COMPONENTS_NAME, name)
      table.insert(COMPONENTS_IS_TAG, isTag)
      table.insert(COMPONENTS_CONSTRUCTOR, constructor)

      return ID
   end
}

-- Special component used to identify the entity that owns a data
local ENTITY_ID_KEY = Component.register('_ECS_ENTITY_ID_')

----------------------------------------------------------------------------------------------------------------------
-- CHUNK
----------------------------------------------------------------------------------------------------------------------
local Chunk  = {}
Chunk.__index = Chunk

local CHUNK_SIZE = 500

--[[
   A block of memory containing the components for entities sharing the same Archetype

   A chunk is a dumb database, it only organizes the components in memory
]]
function  Chunk.new(world, archetype)

   local buffers = {}
    -- um buffer especial que identifica o id da entidade
   buffers[ENTITY_ID_KEY] = table.create(CHUNK_SIZE)

   for _, componentID in pairs(archetype.components) do
      if COMPONENTS_IS_TAG[componentID] then
         -- tag component dont consumes memory
         buffers[componentID] = nil
      else
         buffers[componentID] = table.create(CHUNK_SIZE)
      end
   end

   return setmetatable({
      version     = 0,
      count       = 0,
      world       = world,
      archetype   = archetype,
      buffers     = buffers,
   }, Chunk)
end

--[[
   Performs cleaning of a specific index within this chunk
]]
function  Chunk:clear(index)
   local buffers = self.buffers
   for k in pairs(buffers) do
     buffers[k][index] = nil
   end
end

--[[
   Gets the value of a component for a specific index

   Params
      index {number}
         chunk position

      component {number}
         Component Id
]]
function Chunk:getValue(index, component)
   local buffers = self.buffers
   if buffers[component] == nil then
      return nil
   end
   return buffers[component][index]
end

--[[
   Sets the value of a component to a specific index

   Params
      index {number}
         chunk position

      component {number}
         Component Id

      value {any}
         Value to be persisted in memory
]]
function Chunk:setValue(index, component, value)
   local buffers = self.buffers
   if buffers[component] == nil then
      return
   end
   buffers[component][index] = value
end

--[[
   Get all buffer data at a specific index
]]
function Chunk:get(index)
   local data = {}
   local buffers = self.buffers
   for component in pairs(buffers) do
      data[component] = buffers[component][index]
   end
   return data
end

--[[
   Sets all buffer data to the specific index.

   Copies only the data of the components existing in this chunk (therefore, ignores other records)
]]
function Chunk:set(index, data)
   local buffers = self.buffers
   for component, value in pairs(data) do
      if buffers[component] ~= nil then
         buffers[component][index] = value
      end
   end
end

--[[
   Defines the entity to which this data belongs
]]
function Chunk:setEntityId(index, entity)
   self.buffers[ENTITY_ID_KEY][index] = entity
end


----------------------------------------------------------------------------------------------------------------------
-- ENTITY MANAGER
----------------------------------------------------------------------------------------------------------------------

--[[
   Responsible for managing the entities and chunks of a world
]]
local EntityManager  = {}
EntityManager.__index = EntityManager

function  EntityManager.new(world)
   return setmetatable({
      world = world,

      COUNT = 0,

      --[[
         What is the local index of that entity (for access to other values)

         @Type { [entityID] : { archetype: string, chunk: number, chunkIndex: number } }
      ]]
      ENTITIES = {},

      --[[
         { 
            [archetypeID] : {
               -- The number of entities currently stored
               count: number
               -- What is the index of the last free chunk to use?
               lastChunk:number,
               -- Within the available chunk, what is the next available index for allocation?          
               nextChunkIndex:number,               
               chunks: Array<Chunk>}
            }
      ]]
      ARCHETYPES   = {}
   }, EntityManager)
end

--[[
   Reserve space for an entity in a chunk of this archetype

   It is important that changes in the main EntityManager only occur after the
   execution of the current frame (script update), as some scripts run in parallel,
   so it can point to the wrong index during execution

   The strategy to avoid these problems is that the world has 2 different EntityManagers,
      1 - Primary EntityManager
         Where are registered the entities that will be updated in the update of the scripts
      2 - Secondary EntityManager
         Where the system registers the new entities created during the execution of the
         scripts. After completing the current run, all these new entities are copied to
         the primary EntityManager
]]
function  EntityManager:set(entityID, archetype)

   local archetypeID = archetype.id
   local entity      = self.ENTITIES[entityID]

   local oldEntityData = nil

   -- entity is already registered with this entity manager?
   if entity ~= nil then
      if entity.archetype == archetypeID then
         -- entity is already registered in the informed archetype, nothing to do
         return
      end

      --Different archetype
      -- back up old data
      oldEntityData = self.ARCHETYPES[entity.archetype].chunks[entity.chunk]:get(entity.chunkIndex)

      -- removes entity from the current (and hence chunk) archetype
      self:remove(entityID)
   end

   -- Check if chunk is available (may be the first entity for the informed archetype)
   if self.ARCHETYPES[archetypeID] == nil then
      -- there is no chunk for this archetype, start the list
      self.ARCHETYPES[archetypeID] = {
         count          = 0,
         lastChunk      = 1,
         nextChunkIndex = 1,
         chunks         = { Chunk.new(self.world, archetype) }
      }
   end

   -- add entity at the end of the correct chunk
   local db = self.ARCHETYPES[archetypeID]

   -- new entity record
   self.ENTITIES[entityID] = {
      archetype   = archetypeID,
      chunk       = db.lastChunk,
      chunkIndex  = db.nextChunkIndex
   }
   self.COUNT = self.COUNT + 1

   local chunk = db.chunks[db.lastChunk]

   -- Clears any memory junk
   chunk:clear(db.nextChunkIndex)

    -- update entity indexes
    if oldEntityData ~= nil then
      -- if it's archetype change, restore backup of old data
      chunk:set(db.nextChunkIndex, oldEntityData)
    end
    chunk:setEntityId(db.nextChunkIndex, entityID)

   db.count = db.count + 1
   chunk.count = db.nextChunkIndex

   -- update chunk index
   db.nextChunkIndex = db.nextChunkIndex + 1

   -- marks the new version of chunk (moment that changed)
   chunk.version = self.world.version

   -- if the chunk is full, it already creates a new chunk to welcome new future entities
   if db.nextChunkIndex > CHUNK_SIZE  then
      db.lastChunk            = db.lastChunk + 1
      db.nextChunkIndex       = 1
      db.chunks[db.lastChunk] = Chunk.new(self.world, archetype)
   end
end

--[[
   Removes an entity from this entity manager

   Clean indexes and reorganize data in Chunk

   It is important that changes in the main EntityManager only
   occur after the execution of the current frame (script update),
   as some scripts run in parallel, so it can point to the wrong
   index during execution.

   The strategy to avoid such problems is for the system to register
   in a separate table the IDs of the entities removed during the
   execution of the scripts. Upon completion of the current run,
   requests to actually remove these entities from the main EntityManager
]]
function  EntityManager:remove(entityID)
   local entity = self.ENTITIES[entityID]

   if entity == nil then
      return
   end

   local db = self.ARCHETYPES[entity.archetype]
   local chunk = db.chunks[entity.chunk]

   -- clear data in chunk
   chunk:clear(entity.chunkIndex)
   chunk.count = chunk.count - 1

   -- clears entity references
   self.ENTITIES[entityID] = nil
   self.COUNT = self.COUNT - 1
   db.count = db.count - 1

   -- Adjust chunks, avoid holes
   if db.nextChunkIndex == 1 then
      -- the last chunk is empty and an item from a previous chunk has been removed
      -- system should remove this chunk (as there is a hole in the previous chunks that must be filled before)
      db.chunks[db.lastChunk] = nil
      db.lastChunk      = db.lastChunk - 1
      db.nextChunkIndex = CHUNK_SIZE + 1 -- (+1, next steps get -1)
   end

   if db.count > 0 then
      if db.nextChunkIndex > 1 then
         -- Moves the last item of the last chunk to the position that was left open, for
         -- this, it is necessary to find out which entity belongs, in order to keep
         -- the references consistent
         local otherEntityData = db.chunks[db.lastChunk]:get(db.nextChunkIndex-1)
         db.chunks[entity.chunk]:set(entity.chunkIndex, otherEntityData)
   
         -- backs down the note and clears the unused record
         db.nextChunkIndex = db.nextChunkIndex - 1
         db.chunks[db.lastChunk]:clear(db.nextChunkIndex)
   
         -- update entity indexes
         local otherEntityID     = otherEntityData[ENTITY_ID_KEY]
         local otherEntity       = self.ENTITIES[otherEntityID]
         otherEntity.chunk       = entity.chunk
         otherEntity.chunkIndex  = entity.chunkIndex
      end
   else
      db.nextChunkIndex = db.nextChunkIndex - 1
   end
end

--[[
   How many entities does this EntityManager have
]]
function EntityManager:count()
   return self.COUNT
end

--[[
   Performs the cleaning of an entity's data WITHOUT REMOVING IT.

   Used when running scripts when a script requests the removal of an
   entity. As the system postpones the actual removal until the end
   of the execution of the scripts, at this moment it only performs
   the cleaning of the data (Allowing the subsequent scripts to
   perform the verification)
]]
function EntityManager:clear(entityID)
   local entity = self.ENTITIES[entityID]
   if entity == nil then
      return
   end

   local chunk = self.ARCHETYPES[entity.archetype].chunks[entity.chunk]
   chunk:clear(entity.chunkIndex)
end

--[[
   Gets the current value of an entity component

   Params
      entity {number} 
      component {number}
]]
function EntityManager:getValue(entityID, component)
   local entity = self.ENTITIES[entityID]
   if entity == nil then
      return nil
   end

   return self.ARCHETYPES[entity.archetype].chunks[entity.chunk]:getValue(entity.chunkIndex, component)
end

--[[
   Saves the value of an entity component

   Params
      entity {number}
         Entity Id to be changed

      component {number}
         Component ID

      value {any}
         New value
]]
function EntityManager:setValue(entityID, component, value)
   local entity = self.ENTITIES[entityID]
   if entity == nil then
      return
   end

   local chunk = self.ARCHETYPES[entity.archetype].chunks[entity.chunk]

   chunk:setValue(entity.chunkIndex, component, value)
end

--[[
   Gets all values of the components of an entity

   Params
      entity {number}
         Entity ID
]]
function EntityManager:getData(entityID)
   local entity = self.ENTITIES[entityID]
   if entity == nil then
      return nil
   end

   local chunk = self.ARCHETYPES[entity.archetype].chunks[entity.chunk]
   return chunk:get(entity.chunkIndex)
end

--[[
   Saves the value of an entity component

   Params
      entity {number}
         Entity Id to be changed

      component {number}
         Component ID

      data {table}
         Table with the new values that will be persisted in memory in this chunk
]]
function EntityManager:setData(entityID, component, data)
   local entity = self.ENTITIES[entityID]
   if entity == nil then
      return
   end

   local chunk = self.ARCHETYPES[entity.archetype].chunks[entity.chunk]
   chunk:set(entity.chunkIndex, component, data)
end


--[[
   Gets an entity's chunk and index
]]
function EntityManager:getEntityChunk(entityID)
   local entity = self.ENTITIES[entityID]
   if entity == nil then
      return
   end

   return self.ARCHETYPES[entity.archetype].chunks[entity.chunk], entity.chunkIndex
end

--[[
   Gets all chunks that match the given filter

   Params
      filterFn {function(components) => boolean}
]]
function EntityManager:filterChunks(filterMatch)
   local chunks = {}
   for archetypeID, db in pairs(self.ARCHETYPES) do
      if filterMatch(ARCHETYPES[archetypeID].components) then
         for i, chunk in pairs(db.chunks) do
            table.insert(chunks, chunk)
         end
      end
   end
   return chunks
end

----------------------------------------------------------------------------------------------------------------------
-- SYSTEM
----------------------------------------------------------------------------------------------------------------------
local SYSTEM                 = {}
local SYSTEM_INDEX_BY_NAME   = {}

--[[
   Represents the logic that transforms component data of an entity from its current 
   state to its next state. A system runs on entities that have a specific set of 
   component types.
]]
local System  = {}

--[[
   Allow to create new System Class Type

   Params:
      config {

         name: string,
            Unique name for this System

         requireAll|requireAny: Array<number|string>,
            components this system expects the entity to have before it can act on. If you want 
            to create a system that acts on all entities, enter nil

         rejectAll|rejectAny: Array<number|string>,
            Optional It allows informing that this system will not be invoked if the entity has any of these components

         step: render|process|transform Defaults to process
            Em qual momento, durante a execução de um Frame do Roblox, este sistema deverá ser executado (https://developer.roblox.com/en-us/articles/task-scheduler)
            render      : RunService.RenderStepped
            process     : RunService.Stepped
            transform   : RunService.Heartbeat

         order: number,
            Allows you to define the execution priority level for this system

         readonly: boolean, (WIP)
            Indicates that this system does not change entities and components, so it can be executed
            in parallel with other systems in same step and order

         update: function(time, world, dirty, entity, index, [component_N_items...]) -> boolean
            Invoked in updates, limited to the value set in the "frequency" attribute
         			 	
			beforeUpdate(time: number): void
			 	Invoked before updating entities available for this system.
			 	It is only invoked when there are entities with the characteristics
			 	expected by this system	  	 
			 
			@TODO afterUpdate(time: number, entities: Entity[]): void
			 	Invoked after performing update of entities available for this system.
			 	It is only invoked when there are entities with the characteristics
			 	expected by this system
			 	
			@TODO change(entity: Entity, added?: Component<any>, removed?: Component<any>): void
			 	 Invoked when an expected feature of this system is added or removed from the entity
			 	 			 	 
			   enter(entity: Entity): void;
			 	Invoked when:
			    	a) An entity with the characteristics (components) expected by this system is 
			    		added in the world;
			     	b) This system is added in the world and this world has one or more entities with 
			     		the characteristics expected by this system;
			     	c) An existing entity in the same world receives a new component at runtime 
			     		and all of its new components match the standard expected by this system.
			     		
			@TODO exit(entity: Entity): void;
				Invoked when:
     				a) An entity with the characteristics (components) expected by this system is 
     					removed from the world;
    				b) This system is removed from the world and this world has one or more entities 
    					with the characteristics expected by this system;
     				c) An existing entity in the same world loses a component at runtime and its new 
     					component set no longer matches the standard expected by this system
   }
]]
function System.register(config)

   if config == nil then
      error('System configuration is required for its creation')
   end

   if config.name == nil then
      error('The system "name" is required for registration')
   end

   if SYSTEM_INDEX_BY_NAME[config.name] ~= nil then
      error('Another System already registered with that name')
   end

   if config.requireAll == nil and config.requireAny == nil then
      error('It is necessary to define the components using the "requireAll" or "requireAny" parameters')
   end

   if config.requireAll ~= nil and config.requireAny ~= nil then
      error('It is not allowed to use the "requireAll" and "requireAny" settings simultaneously')
   end

   if config.requireAll ~= nil then
      config.requireAllOriginal = config.requireAll
      config.requireAll = safeNumberTable(config.requireAll)
      if table.getn(config.requireAll) == 0 then
         error('You must enter at least one component id in the "requireAll" field')
      end
   elseif config.requireAny ~= nil then
      config.requireAnyOriginal = config.requireAny
      config.requireAny = safeNumberTable(config.requireAny)
      if table.getn(config.requireAny) == 0 then
         error('You must enter at least one component id in the "requireAny" field')
      end
   end

   if config.rejectAll ~= nil and config.rejectAny ~= nil then
      error('It is not allowed to use the "rejectAll" and "rejectAny" settings simultaneously')
   end

   if config.rejectAll ~= nil then
      config.rejectAll = safeNumberTable(config.rejectAll)
      if table.getn(config.rejectAll) == 0 then
         error('You must enter at least one component id in the "rejectAll" field')
      end
   elseif config.rejectAny ~= nil then
      config.rejectAny = safeNumberTable(config.rejectAny)
      if table.getn(config.rejectAny) == 0 then
         error('You must enter at least one component id in the "rejectAny" field')
      end
   end

   if config.step == nil then
      config.step = 'transform'
   end

   if config.step ~= 'render' and config.step ~= 'process' and config.step ~= 'processIn' and config.step ~= 'processOut' and config.step ~= 'transform' then
      error('The "step" parameter must be "render", "process", "transform", "processIn" or "processOut"')
   end

   if config.order == nil or config.order < 0 then
		config.order = 50
   end

   -- imutable
   table.insert(SYSTEM, {
      name                 = config.name,
      requireAll           = config.requireAll,
      requireAny           = config.requireAny,
      requireAllOriginal   = config.requireAllOriginal,
      requireAnyOriginal   = config.requireAnyOriginal,
      rejectAll            = config.rejectAll,
      rejectAny            = config.rejectAny,
      beforeUpdate         = config.beforeUpdate,
      update               = config.update,
      onEnter              = config.onEnter,
      step                 = config.step,
      order                = config.order
   })

   local ID = table.getn(SYSTEM)

   SYSTEM_INDEX_BY_NAME[config.name] = ID

	return ID
end

--[[
   Generates an execution plan for the systems.
   An execution plan is a function that, when called, will perform the orderly processing of these systems.
]]
local function NewExecutionPlan(world, systems)

   local updateSteps = {
      render         = {},
      process        = {},
      transform      = {},
      processIn    = {},
      processOut   = {},
   }

   -- systems that process the onEnter event
   local onEnterSystems = {}

   for k, system in pairs(systems) do
      -- component filter, used to obtain the correct chunks in the entity manager
      system.filter = componentFilter(system.requireAll, system.requireAny, system.rejectAll, system.rejectAny)

      if system.update ~= nil then
         if updateSteps[system.step][system.order] == nil then
            updateSteps[system.step][system.order] = {}
            --table.insert(updateStepsOrder[system.step], system.order)
         end

         table.insert(updateSteps[system.step][system.order], system)
      end

      if system.onEnter ~= nil then
         table.insert(onEnterSystems, system)
      end
   end

   -- Update systems
   local onUpdate = function(step, entityManager, time, interpolation)
      for i, stepSystems  in pairs(updateSteps[step]) do
         for j, system  in pairs(stepSystems) do
            -- execute system update

            system.lastUpdate = time

            -- what components the system expects
            local whatComponents = system.requireAllOriginal
            if whatComponents == nil then
               whatComponents = system.requireAnyOriginal
            end

            local whatComponentsLen    = table.getn(whatComponents)
            local systemVersion        = system.version

            -- Gets all the chunks that apply to this system
            local chunks = entityManager:filterChunks(system.filter)

            -- update: function(time, world, dirty, entity, index, [component_N_items...]) -> boolean
            local updateFn = system.update

            -- increment Global System Version (GSV), before system update
            world.version = world.version + 1

            if system.beforeUpdate ~= nil then
               system.beforeUpdate(time, interpolation, world, system)
            end

            for k, chunk in pairs(chunks) do
               -- if the version of the chunk is larger than the system, it means 
               -- that this chunk has already undergone a change that was not performed 
               -- after the last execution of this system
               local dirty = chunk.version == 0 or chunk.version > systemVersion
               local buffers = chunk.buffers
               local entityIDBuffer = buffers[ENTITY_ID_KEY]
               local componentsData = table.create(whatComponentsLen)

               local hasChangeThisChunk = false

               for l, compID in ipairs(whatComponents) do
                  if buffers[compID] ~= nil then
                     componentsData[l] = buffers[compID]
                  else
                     componentsData[l] = {}
                  end
               end

               for index = 1, chunk.count do
                  if updateFn(time, world, dirty, entityIDBuffer[index], index, table.unpack(componentsData)) then
                     hasChangeThisChunk = true
                  end
               end

               if hasChangeThisChunk then
                  -- If any system execution informs you that it has changed data in
                  -- this chunk, it then performs the versioning of the chunk
                  chunk.version = world.version
               end
            end

            -- update last system version with GSV
            system.version = world.version
         end
      end
   end

   local onEnter = function(onEnterEntities, entityManager, time)
      -- increment Global System Version (GSV), before system update
      world.version = world.version + 1

      -- temporary filters
      local systemsFilters = {}

      for entityID, newComponents in pairs(onEnterEntities) do

         -- get the chunk and index of this entity
         local chunk, index = entityManager:getEntityChunk(entityID)
         if chunk == nil then
            continue
         end

         local buffers = chunk.buffers
            
         for j, system in pairs(onEnterSystems) do

            -- system does not apply to the archetype of that entity
            if not system.filter(chunk.archetype.components) then
               continue
            end

            -- what components the system expects
            local whatComponents = system.requireAllOriginal
            if whatComponents == nil then
               whatComponents = system.requireAnyOriginal
            end

            if systemsFilters[system.id] == nil then
               systemsFilters[system.id] = componentFilter(nil, newComponents, nil, nil)
            end

            -- components received are not in the list of components expected by the system
            if not systemsFilters[system.id](whatComponents) then
               continue
            end
            
            local componentsData = table.create(table.getn(whatComponents))

            for l, compID in ipairs(whatComponents) do
               if buffers[compID] ~= nil then
                  componentsData[l] = buffers[compID]
               else
                  componentsData[l] = {}
               end
            end

            -- onEnter: function(world, entity, index, [component_N_items...]) -> boolean
            if system.onEnter(time, world, entityID, index, table.unpack(componentsData)) then
               -- If any system execution informs you that it has changed data in
               -- this chunk, it then performs the versioning of the chunk
               chunk.version = world.version
            end
         end
      end
   end

   return onUpdate, onEnter
end

----------------------------------------------------------------------------------------------------------------------
-- ECS
----------------------------------------------------------------------------------------------------------------------

local ECS = {
	Component 	= Component,
	System 		= System
}

-- World constructor
function ECS.newWorld(systems, config)

   if config == nil then
      config = {}
   end

   -- frequence: number,
   -- The maximum times per second this system should be updated. Defaults 30
   if config.frequence == nil then
      config.frequence = 30
   end

   local safeFrequency  = math.round(math.abs(config.frequence)/5)*5
   if safeFrequency < 5 then
      safeFrequency = 5
   end

   if config.frequence ~= safeFrequency then
      config.frequence = safeFrequency
      print(string.format(">>> ATTENTION! The execution frequency of world has been changed to %d <<<", safeFrequency))
   end
   
   local SEQ_ENTITY 	= 1

   -- systems in this world
   local worldSystems = {}

   -- System execution plan
   local updateExecPlan, enterExecPlan

   local proccessDeltaTime = 1000/config.frequence/1000

   -- INTERPOLATION: The proportion of time since the previous transform relative to proccessDeltaTime
   local interpolation = 1

   local FIRST_UPDATE_TIME = nil

   local timeLastFrame = 0

   -- The time at the beginning of this frame. The world receives the current time at the beginning 
   -- of each frame, with the value increasing per frame.
   local timeCurrentFrame  = 0

   -- The time the latest proccess step has started.
   local timeProcess  = 0

   local timeProcessOld = 0

   -- The completion time in seconds since the last frame. This property provides the time between the current and previous frame.
   local timeDelta = 0

   -- if execution is slow, perform a maximum of 10 simultaneous 
   -- updates in order to keep the fixrate
   local maxSkipFrames = 10

   local lastKnownArchetypeInstant = 0

   --[[
      The main EntityManager

      It is important that changes in the main EntityManager only occur after the execution 
      of the current frame (script update), as some scripts run in parallel, so 
      it can point to the wrong index during execution
   
      The strategy to avoid these problems is that the world has 2 different EntityManagers,
         1 - Primary EntityManager
            Where are registered the entities that will be updated in the update of the scripts
         2 - Secondary EntityManager
            Where the system registers the new entities created during the execution of the scripts.
            After completing the current run, all these new entities are copied to the primary EntityManager
   ]]
   local entityManager

   -- The EntityManager used to house the new entities
   local entityManagerNew

   -- The EntityManager used to house the copy of the data of the entity that changed
   -- At the end of the execution of the scripts of the current step, the entity will be updated in the main entity manger
   local entityManagerUpdated

   -- Entities that were removed during execution (only removed after the last execution step)
   local entitiesRemoved = {}

   -- Entities that changed during execution (received or lost components, therefore, changed the archetype)
   local entitiesUpdated = {}

   -- Entities that were created during the execution of the update, will be transported from "entityManagerNew" to "entityManager"
   local entitiesNew = {}

   -- reference to the most updated archetype of an entity (dirty)
   -- Changing the archetype does not reflect the current execution of the scripts, it is only used 
   -- for updating the data in the main entity manager
   local entitiesArchetypes  = {}

   local world

   -- Environment cleaning method
   local cleanupEnvironmentFn

   -- True when environment has been modified while a system is running
   local dirtyEnvironment = false

	world = {

      version = 0,
      frequence = config.frequence,

      --[[
         Create a new entity
      ]]
      create = function()
         local ID = SEQ_ENTITY
         SEQ_ENTITY = SEQ_ENTITY + 1

         entityManagerNew:set(ID, ARCHETYPE_EMPTY)

         -- informs that it has a new entity
         entitiesNew[ID] = true

         entitiesArchetypes[ID] = ARCHETYPE_EMPTY

         dirtyEnvironment = true

         return ID
      end,

      --[[
         Get entity compoment data
      ]]
      get = function(entity, component)
         if entitiesNew[entity] == true then
            return entityManagerNew:getValue(entity, component)
         else
            return entityManager:getValue(entity, component)
         end
      end,

      --[[
         Defines the value of a component for an entity
      ]]
      set = function(entity, component, ...)
         local archetype = entitiesArchetypes[entity]
         if archetype == nil then
            -- entity doesn exist
            return
         end

         dirtyEnvironment = true

         local archetypeNew = archetype:with(component)
         local archetypeChanged = archetype ~= archetypeNew
         if archetypeChanged then
            entitiesArchetypes[entity] = archetypeNew
         end

         local value = COMPONENTS_CONSTRUCTOR[component](table.unpack({...}))

         if entitiesNew[entity] == true then
            if archetypeChanged then
               entityManagerNew:set(entity, archetypeNew)
            end

            entityManagerNew:setValue(entity, component, value)
         else
            if archetypeChanged then
               -- entity has undergone an archetype change. Registers a copy in another entity 
               -- manager, which will be processed after the execution of the current scripts
               if entitiesUpdated[entity] == nil then
                  entitiesUpdated[entity] = {
                     received = {},
                     lost = {}
                  }
                  -- the first time you are modifying the components of this entity in 
                  -- this execution, you need to copy the data of the entity
                  entityManagerUpdated:set(entity, archetypeNew)
                  entityManagerUpdated:setData(entity, entityManager:getData(entity))
               else
                  -- just perform the archetype update on the entityManager
                  entityManagerUpdated:set(entity, archetypeNew)
               end
            end

            if entitiesUpdated[entity]  ~= nil then
               -- register a copy of the value
               entityManagerUpdated:setValue(entity, component, value)

               -- removed before, received again
               local ignoreChange = false
               for k, v in pairs(entitiesUpdated[entity].lost) do
                  if v == component then
                     table.remove(entitiesUpdated[entity].lost, k)
                     ignoreChange = true
                     break
                  end
               end
               if not ignoreChange then
                  table.insert(entitiesUpdated[entity].received, component)
               end
            end

            -- records the value in the current entityManager, used by the scripts
            entityManager:setValue(entity, component, value)
         end
      end,

      --[[
         Removing a entity or Removing a component from an entity at runtime
      ]]
      remove = function(entity, component)
         local archetype = entitiesArchetypes[entity]
         if archetype == nil then
            return
         end

         if entitiesRemoved[entity] == true then
            return
         end

         dirtyEnvironment = true

         if component == nil then
            -- remove entity
            if entitiesNew[entity] == true then
               entityManagerNew:remove(entity)
               entitiesNew[entity] = nil
               entitiesArchetypes[entity] = nil
            else
               if entitiesRemoved[entity] == nil then
                  entitiesRemoved[entity] = true
               end
            end
         else
            -- remove component from entity
            local archetypeNew = archetype:without(component)
            local archetypeChanged = archetype ~= archetypeNew
            if archetypeChanged then
               entitiesArchetypes[entity] = archetypeNew
            end
            if entitiesNew[entity] == true then
               if archetypeChanged then
                  entityManagerNew:set(entity, archetypeNew)
               end
            else
               if archetypeChanged then

                  -- entity has undergone an archetype change. Registers a copy in
                  -- another entity manager, which will be processed after the execution of the current scripts
                  if entitiesUpdated[entity] == nil then
                     entitiesUpdated[entity] = {
                        received = {},
                        lost = {}
                     }
                     -- the first time you are modifying the components of this entity
                     -- in this execution, you need to copy the data of the entity
                     entityManagerUpdated:set(entity, archetypeNew)
                     entityManagerUpdated:setData(entity, entityManager:getData(entity))
                  else
                     -- just perform the archetype update on the entityManager
                     entityManagerUpdated:set(entity, archetypeNew)
                  end
               end

               if entitiesUpdated[entity] ~= nil then
                  -- register a copy of the value
                  entityManagerUpdated:setValue(entity, component, nil)

                  -- received before, removed again
                  local ignoreChange = false
                  for k, v in pairs(entitiesUpdated[entity].received) do
                     if v == component then
                        table.remove(entitiesUpdated[entity].received, k)
                        ignoreChange = true
                        break
                     end
                  end
                  if not ignoreChange then
                     table.insert(entitiesUpdated[entity].lost, component)
                  end
               end

               -- records the value in the current entityManager, used by the scripts
               entityManager:setValue(entity, component, nil)
            end
         end
      end,

      --[[
         Get entity compoment data
      ]]
      has = function(entity, component)
         if entitiesArchetypes[entity] == nil then
            return false
         end

         return entitiesArchetypes[entity]:has(component)
      end,

      --[[
         Remove an entity from this world
      ]]
      addSystem = function (systemID, order, config)
         if systemID == nil then
            return
         end

         if SYSTEM[systemID] == nil then
            error('There is no registered system with the given ID')
         end

         if worldSystems[systemID] ~= nil then
            -- This system has already been registered in this world
            return
         end

         if entityManager:count() > 0 or entityManagerNew:count() > 0 then
            error('Adding systems is not allowed after adding entities in the world')
         end

         if config == nil then
            config = {}
         end

         local system = {
            id                   = systemID,
            name                 = SYSTEM[systemID].name,
            requireAll           = SYSTEM[systemID].requireAll,
            requireAny           = SYSTEM[systemID].requireAny,
            requireAllOriginal   = SYSTEM[systemID].requireAllOriginal,
            requireAnyOriginal   = SYSTEM[systemID].requireAnyOriginal,
            rejectAll            = SYSTEM[systemID].rejectAll,
            rejectAny            = SYSTEM[systemID].rejectAny,
            beforeUpdate         = SYSTEM[systemID].beforeUpdate,
            update               = SYSTEM[systemID].update,
            onEnter              = SYSTEM[systemID].onEnter,
            step                 = SYSTEM[systemID].step,
            order                = SYSTEM[systemID].order,
            -- instance properties
            version              = 0,
            lastUpdate           = timeProcess,
            config               = config
         }

         if order ~= nil and order < 0 then
            system.order = 50
         end

         worldSystems[systemID] = system

         -- forces re-creation of the execution plan
         lastKnownArchetypeInstant = 0
      end,

      --[[
         Is the Entity still alive?
      ]]
      alive = function(entity)
         if entitiesArchetypes[entity] == nil then
            return false
         end

         if entitiesNew[entity] == true then
            return false
         end

         if entitiesRemoved[entity] == true then
            return false
         end

         return true
      end,

      --[[
         Remove all entities and systems
      ]]
      destroy = function()
         --[[
         @TODO: Destroy
         for i = #self.entities, 1, -1 do
            self:removeEntity(self.entities[i])
         end

         for i = #self.systems, 1, -1 do
            self:removeSystem(self.systems[i])
         end

         self._steppedConn:Disconnect()      
         ]]
      end,
      --[[
         Realizes world update
      ]]
      update = function(step, now)
         if not RunService:IsRunning() then
            return
         end

         if FIRST_UPDATE_TIME == nil then
            FIRST_UPDATE_TIME = now
         end

         -- corrects for internal time
         now = now - FIRST_UPDATE_TIME
         
         -- need to update execution plan?
         if lastKnownArchetypeInstant < LAST_ARCHETYPE_INSTANT then
            updateExecPlan, enterExecPlan = NewExecutionPlan(world, worldSystems)
            lastKnownArchetypeInstant = LAST_ARCHETYPE_INSTANT
         end

         if step ~= 'process' then
            -- executed only once per frame

            if timeProcess ~= timeProcessOld then
               interpolation = 1 + (now - timeProcess)/proccessDeltaTime
            else
               interpolation = 1
            end

            if step == 'processIn' then

               -- first step, initialize current frame time
               timeCurrentFrame  = now
               if timeLastFrame == 0 then
                  timeLastFrame = timeCurrentFrame
               end
               if timeProcess == 0 then
                  timeProcess    = timeCurrentFrame
                  timeProcessOld = timeCurrentFrame
               end
               timeDelta = timeCurrentFrame - timeLastFrame
               interpolation = 1

            elseif step == 'render' then
               -- last step, save last frame time
               timeLastFrame = timeCurrentFrame
            end

            updateExecPlan(step, entityManager, {
               process        = timeProcess,
               frame          = timeCurrentFrame,
               delta          = timeDelta
            }, interpolation)

            while dirtyEnvironment do
               cleanupEnvironmentFn()
            end
         else

            local timeProcessOldTmp = timeProcess

            --[[
               Adjusting the framerate, the world must run on the same frequency, 
               this ensures determinism in the execution of the scripts

               Each system in "transform" step is executed at a predetermined frequency (in Hz).

               Ex. If the game is running on the client at 30FPS but a system needs to be run at
               120Hz or 240Hz, this logic will ensure that this frequency is reached

               @see
                  https://gafferongames.com/post/fix_your_timestep/
                  https://gameprogrammingpatterns.com/game-loop.html
                  https://bell0bytes.eu/the-game-loop/
            ]]
            local nLoops = 0
            local updated =  false
            -- Fixed time is updated in regular intervals (equal to fixedDeltaTime) until time property is reached.
            while timeProcess < timeCurrentFrame and nLoops < maxSkipFrames do

               debugF('Update')

               updated = true
               -- need to update execution plan?
               if lastKnownArchetypeInstant < LAST_ARCHETYPE_INSTANT then
                  updateExecPlan, enterExecPlan = NewExecutionPlan(world, worldSystems)
                  lastKnownArchetypeInstant = LAST_ARCHETYPE_INSTANT
               end

               updateExecPlan(step, entityManager, {
                  process        = timeProcess,
                  frame          = timeCurrentFrame,
                  delta          = timeDelta
               }, 1)
               
               while dirtyEnvironment do
                  cleanupEnvironmentFn()
               end

               nLoops   += 1
               timeProcess += proccessDeltaTime
            end

            if updated then
               timeProcessOld = timeProcessOldTmp
            end
         end
      end
   }

   -- cleans up after running scripts
   cleanupEnvironmentFn = function()

      if not dirtyEnvironment then
         -- fast exit
         return
      end

      dirtyEnvironment = false

      -- 1: remove entities
      -- @TODO: Event onRemove?
      for entityID, V in pairs(entitiesRemoved) do
         entityManager:remove(entityID)
         entitiesArchetypes[entityID] = nil

         -- was removed after update
         if entitiesUpdated[entityID] ~= nil then
            entitiesUpdated[entityID] = nil
            entityManagerUpdated:remove(entityID)
         end
      end

      local haveOnEnter = false
      local onEnterEntities = {}

      -- 2: Update entities in memory
      -- @TODO: Event onChange?
      for entityID, updated in pairs(entitiesUpdated) do
         entityManager:set(entityID, entitiesArchetypes[entityID])
         entityManager:setData(entityID, entityManagerUpdated:getData(entityID))
         entityManagerUpdated:remove(entityID)

         if table.getn(updated.received) > 0 then
            onEnterEntities[entityID] = updated.received
            haveOnEnter = true
         end
      end
      entitiesUpdated = {}

      -- 3: Add new entities     
      for entityID, V in pairs(entitiesNew) do
         entityManager:set(entityID, entitiesArchetypes[entityID])        
         entityManager:setData(entityID,  entityManagerNew:getData(entityID))
         entityManagerNew:remove(entityID)
         onEnterEntities[entityID] = entitiesArchetypes[entityID].components
         haveOnEnter = true
      end
      entitiesNew = {}

      if haveOnEnter then
         enterExecPlan(onEnterEntities, entityManager)
         onEnterEntities = nil
      end
   end

   -- all managers in this world
   entityManager        = EntityManager.new(world)
   entityManagerNew     = EntityManager.new(world)
   entityManagerUpdated = EntityManager.new(world)

   -- add user systems
   if systems ~= nil then
		for i, system in pairs(systems) do
			world.addSystem(system)
		end
   end

   -- add default systems
   if not config.disableDefaultSystems then
      
      -- processIn
      world.addSystem(ECS.Util.BasePartToEntityProcessInSystem)

      -- process
      world.addSystem(ECS.Util.MoveForwardSystem)

      -- processOut
      world.addSystem(ECS.Util.EntityToBasePartProcessOutSystem)

      -- transform
      world.addSystem(ECS.Util.BasePartToEntityTransformSystem)
      world.addSystem(ECS.Util.EntityToBasePartTransformSystem)
      world.addSystem(ECS.Util.EntityToBasePartInterpolationTransformSystem)
   end

   if not config.disableAutoUpdate then

      world._steppedConn = RunService.Stepped:Connect(function()
         world.update('processIn', tick())
         world.update('process', tick())
         world.update('processOut', tick())
      end)

      world._heartbeatConn = RunService.Heartbeat:Connect(function()
         world.update('transform', tick())
      end)

      world._renderSteppedConn = RunService.RenderStepped:Connect(function()
         world.update('render', tick())
      end)
   end

	return world
end


----------------------------------------------------------------------------------------------------------------------
-- UTILITY COMPONENTS & SYSTEMS
----------------------------------------------------------------------------------------------------------------------

ECS.Util = {}

-- Creates an entity related to a BasePart
function ECS.Util.NewBasePartEntity(world, part, syncBasePartToEntity, syncEntityToBasePart, interpolate)
   local entityID = world.create()

   world.set(entityID, ECS.Util.BasePartComponent, part)
   world.set(entityID, ECS.Util.PositionComponent, part.CFrame.Position)
   world.set(entityID, ECS.Util.RotationComponent, part.CFrame.RightVector, part.CFrame.UpVector, part.CFrame.LookVector)

   if syncBasePartToEntity then 
      world.set(entityID, ECS.Util.BasePartToEntitySyncComponent)
   end

   if syncEntityToBasePart then 
      world.set(entityID, ECS.Util.EntityToBasePartSyncComponent)
   end

   if interpolate then
      world.set(entityID, ECS.Util.PositionInterpolationComponent, part.CFrame.Position)
      world.set(entityID, ECS.Util.RotationInterpolationComponent, part.CFrame.RightVector, part.CFrame.UpVector, part.CFrame.LookVector)
   end

   return entityID
end

-- A component that facilitates access to BasePart
ECS.Util.BasePartComponent = Component.register('BasePart', function(object)
   if object == nil or object['IsA'] == nil or object:IsA('BasePart') == false then
      error("This component only works with BasePart objects")
   end

   return object
end)

-- Tag, indicates that the entity must be synchronized with the data from the BasePart (workspace)
ECS.Util.BasePartToEntitySyncComponent = Component.register('BasePartToEntitySync', nil, true)

-- Tag, indicates that the BasePart (workspace) must be synchronized with the existing data in the Entity (ECS)
ECS.Util.EntityToBasePartSyncComponent = Component.register('EntityToBasePartSync', nil, true)

-- Component that works with a position Vector3
ECS.Util.PositionComponent = Component.register('Position', function(position)
   if position ~= nil and typeof(position) ~= 'Vector3' then
      error("This component only works with Vector3 objects")
   end

   if position == nil then 
      position = Vector3.new(0, 0, 0)
   end

   return position
end)

-- Allows to register two last positions (Vector3) to allow interpolation
ECS.Util.PositionInterpolationComponent = Component.register('PositionInterpolation', function(position)
   if position ~= nil and typeof(position) ~= 'Vector3' then
      error("This component only works with Vector3 objects")
   end

   if position == nil then 
      position = Vector3.new(0, 0, 0)
   end

   return {position, position}
end)

local VEC3_R = Vector3.new(1, 0, 0)
local VEC3_U = Vector3.new(0, 1, 0)
local VEC3_F = Vector3.new(0, 0, 1)

--[[
   Rotational vectors that represents the object in the 3d world. 
   To transform into a CFrame use CFrame.fromMatrix(pos, rot[1], rot[2], rot[3] * -1)

   Params
      lookVector  {Vector3}   @See CFrame.LookVector
      rightVector {Vector3}   @See CFrame.RightVector
      upVector    {Vector3}   @See CFrame.UpVector

   @See 
      https://devforum.roblox.com/t/understanding-cframe-frommatrix-the-replacement-for-cframe-new/593742
      https://devforum.roblox.com/t/handling-the-edge-cases-of-cframe-frommatrix/632465
]]
ECS.Util.RotationComponent = Component.register('Rotation', function(rightVector, upVector, lookVector)

   if rightVector ~= nil and typeof(rightVector) ~= 'Vector3' then
      error("This component only works with Vector3 objects [param=rightVector]")
   end

   if upVector ~= nil and typeof(upVector) ~= 'Vector3' then
      error("This component only works with Vector3 objects [param=upVector]")
   end

   if lookVector ~= nil and typeof(lookVector) ~= 'Vector3' then
      error("This component only works with Vector3 objects [param=lookVector]")
   end

   if rightVector == nil then
      rightVector = VEC3_R
   end

   if upVector == nil then
      upVector = VEC3_U
   end

   if lookVector == nil then
      lookVector = VEC3_F
   end

   return {rightVector, upVector, lookVector}
end)

-- Allows to record two last rotations (rightVector, upVector, lookVector) to allow interpolation
ECS.Util.RotationInterpolationComponent = Component.register('RotationInterpolation', function(rightVector, upVector, lookVector)

   if rightVector ~= nil and typeof(rightVector) ~= 'Vector3' then
      error("This component only works with Vector3 objects [param=rightVector]")
   end

   if upVector ~= nil and typeof(upVector) ~= 'Vector3' then
      error("This component only works with Vector3 objects [param=upVector]")
   end

   if lookVector ~= nil and typeof(lookVector) ~= 'Vector3' then
      error("This component only works with Vector3 objects [param=lookVector]")
   end

   if rightVector == nil then
      rightVector = VEC3_R
   end

   if upVector == nil then
      upVector = VEC3_U
   end

   if lookVector == nil then
      lookVector = VEC3_F
   end

   return {{rightVector, upVector, lookVector}, {rightVector, upVector, lookVector}}
end)

-- Tag, indicates that the forward movement system must act on this entity
ECS.Util.MoveForwardComponent = Component.register('MoveForward', nil, true)

-- Allows you to define a movement speed for specialized handling systems
ECS.Util.MoveSpeedComponent = Component.register('MoveSpeed', function(speed)
   if speed == nil or typeof(speed) ~= 'number' then 
      error("This component only works with number value")
   end

   return speed
end)

------------------------------------------
--[[
   Utility system that copies the direction and position of a Roblox BasePart to the ECS entity

   Executed in two moments: At the beginning of the "process" step and at the beginning of the "transform" step
]]
---------------------------------------->>
local function BasePartToEntityUpdate(time, world, dirty, entity, index, parts, positions, rotations)

   local changed = false
   local part = parts[index]

   if part ~= nil then

      local position = positions[index]
      local basePos = part.CFrame.Position
      if position == nil or not vectorEQ(basePos, position) then
         positions[index] = basePos
         changed = true
      end

      local rotation    = rotations[index]
      local rightVector =  part.CFrame.RightVector
      local upVector    =  part.CFrame.UpVector
      local lookVector  =  part.CFrame.LookVector
      if rotation == nil or not vectorEQ(rightVector, rotation[1]) or not vectorEQ(upVector, rotation[2]) or not vectorEQ(lookVector, rotation[3]) then
         rotations[index] = {rightVector, upVector, lookVector}
         changed = true
      end
   end

   return changed
end

-- copia dados de basepart para entidade no inicio do processamento, ignora entidades marcadas com Interpolation
ECS.Util.BasePartToEntityProcessInSystem = System.register({
   name  = 'BasePartToEntityProcessIn',
   step  = 'processIn',
   order = 10,
   requireAll = {
      ECS.Util.BasePartComponent,
      ECS.Util.PositionComponent,
      ECS.Util.RotationComponent,
      ECS.Util.BasePartToEntitySyncComponent
   },
   rejectAny = {
      ECS.Util.PositionInterpolationComponent,
      ECS.Util.RotationInterpolationComponent
   },
   update = BasePartToEntityUpdate
})

-- copia dados de um BasePart para entidade no inicio do passo transform
ECS.Util.BasePartToEntityTransformSystem = System.register({
   name  = 'BasePartToEntityTransform',
   step  = 'transform',
   order = 10,
   requireAll = {
      ECS.Util.BasePartComponent,
      ECS.Util.PositionComponent,
      ECS.Util.RotationComponent,
      ECS.Util.BasePartToEntitySyncComponent
   },
   rejectAny = {
      ECS.Util.PositionInterpolationComponent,
      ECS.Util.RotationInterpolationComponent
   },
   update = BasePartToEntityUpdate
})
----------------------------------------<<

------------------------------------------
--[[
   Utility system that copies the direction and position from ECS entity to a Roblox BasePart

   Executed in two moments: At the end of the "process" step and at the end of the "transform" step
]]
---------------------------------------->>

local function EntityToBasePartUpdate(time, world, dirty, entity, index, parts, positions, rotations)

   if not dirty then
      return false
   end

   local changed  = false
   local part     = parts[index]
   local position = positions[index]
   local rotation = rotations[index]
   if part ~= nil then
      local basePos     = part.CFrame.Position
      local rightVector = part.CFrame.RightVector
      local upVector    = part.CFrame.UpVector
      local lookVector  = part.CFrame.LookVector

      -- goal cframe, allow interpolation
      local cframe = part.CFrame

      if position ~= nil and not vectorEQ(basePos, position) then
         cframe = CFrame.fromMatrix(position, rightVector, upVector, lookVector * -1)
         changed = true
      end

      if rotation ~= nil then
         if not vectorEQ(rightVector, rotation[1]) or not vectorEQ(upVector, rotation[2]) or not vectorEQ(lookVector, rotation[3]) then
            cframe = CFrame.fromMatrix(cframe.Position, rotation[1], rotation[2], rotation[3] * -1)
            changed = true
         end
      end

      if changed then
         part.CFrame = cframe
      end
   end

   return changed
end

-- copia dados da entidade para um BaseParte no fim do processamento
ECS.Util.EntityToBasePartProcessOutSystem = System.register({
   name  = 'EntityToBasePartProcess',
   step  = 'processOut',
   order = 100,
   requireAll = {
      ECS.Util.BasePartComponent,
      ECS.Util.PositionComponent,
      ECS.Util.RotationComponent,
      ECS.Util.EntityToBasePartSyncComponent
   },
   update = EntityToBasePartUpdate
})

-- copia dados de uma entidade para um BsePart no passo de transformação, ignora entidades com interpolação
ECS.Util.EntityToBasePartTransformSystem = System.register({
   name  = 'EntityToBasePartTransform',
   step  = 'transform',
   order = 100,
   requireAll = {
      ECS.Util.BasePartComponent,
      ECS.Util.PositionComponent,
      ECS.Util.RotationComponent,
      ECS.Util.EntityToBasePartSyncComponent
   },
   rejectAny = {
      ECS.Util.PositionInterpolationComponent,
      ECS.Util.RotationInterpolationComponent
   },
   update = EntityToBasePartUpdate
})

-- Interpolates the position and rotation of a BasePart in the transform step.
-- Allows the process step to be performed at low frequency and with smooth rendering
local interpolationFactor = 1
ECS.Util.EntityToBasePartInterpolationTransformSystem = System.register({
   name  = 'EntityToBasePartInterpolationTransform',
   step  = 'transform',
   order = 100,
   requireAll = {
      ECS.Util.BasePartComponent,
      ECS.Util.PositionComponent,
      ECS.Util.RotationComponent,
      ECS.Util.PositionInterpolationComponent,
      ECS.Util.RotationInterpolationComponent,
      ECS.Util.EntityToBasePartSyncComponent
   },
   beforeUpdate = function(time, interpolation, world, system)
      interpolationFactor = interpolation
   end,
   update = function(time, world, dirty, entity, index, parts, positions, rotations, positionsInt, rotationsInt)

      local part     = parts[index]
      local position = positions[index]
      local rotation = rotations[index]

      if part ~= nil then
          -- goal cframe, allow interpolation
          local cframe = part.CFrame

         -- swap old and new position, if changed
         if position ~= nil then
            local rightVector = part.CFrame.RightVector
            local upVector    = part.CFrame.UpVector
            local lookVector  = part.CFrame.LookVector

            if not vectorEQ(positionsInt[index][1], position) then
               positionsInt[index][2] = positionsInt[index][1]
               positionsInt[index][1] = position
            end

            local oldPosition = positionsInt[index][2]
            cframe = CFrame.fromMatrix(oldPosition:Lerp(position, interpolationFactor), rightVector, upVector, lookVector * -1)
         end

         -- swap old and new rotation, if changed
         if rotation ~= nil then
            if not vectorEQ(rotationsInt[index][1][1], rotation[1])
               or not vectorEQ(rotationsInt[index][1][2], rotation[2])
               or not vectorEQ(rotationsInt[index][1][3], rotation[3])
            then
               rotationsInt[index][2] = rotationsInt[index][1]
               rotationsInt[index][1] = rotation
            end

            local oldRotation = rotationsInt[index][2]
            cframe = CFrame.fromMatrix(
               cframe.Position,
               oldRotation[1]:Lerp(rotation[1], interpolationFactor),
               oldRotation[2]:Lerp(rotation[2], interpolationFactor),
               (oldRotation[3] * -1):Lerp((rotation[3] * -1), interpolationFactor)
            )
         end

         part.CFrame = cframe
      end

      -- readonly
      return false
   end
})
----------------------------------------<<

-- Simple forward movement system (position = position + speed * lookVector)
local moveForwardSpeedFactor = 1
ECS.Util.MoveForwardSystem = System.register({
   name = 'MoveForward',
   step = 'process',
   requireAll = {
      ECS.Util.MoveSpeedComponent,
      ECS.Util.PositionComponent,
      ECS.Util.RotationComponent,
      ECS.Util.MoveForwardComponent,
   },
   beforeUpdate = function(time, interpolation, world, system)
      moveForwardSpeedFactor = world.frequence/60
   end,
   update = function (time, world, dirty, entity, index, speeds, positions, rotations, forwards)

      local position = positions[index]
      if position ~= nil then

         local rotation = rotations[index]
         if rotation ~= nil then

            local speed = speeds[index]
            if speed ~= nil then
               -- speed/2 = 1 studs per second (120 = frequence)
               positions[index] = position + speed/moveForwardSpeedFactor  * rotation[3]
               return true
            end
         end
      end

      return false
   end
})

-- export ECS lib
return ECS
