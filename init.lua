-- Initial speed of a box.
local SPEED = 10
-- Acceleration of a box.
local ACCEL = 0.1
-- Elevator interface/database version.
local VERSION = 8
-- Maximum time a box can go without players nearby.
local PTIMEOUT = 120

-- Detect optional mods.
local armor_path = minetest.get_modpath("3d_armor")

-- global runtime storage for data and references
-- contains .motors loaded from mod storage and api functions
elevator = {
	boxes		= {}, -- Elevator boxes in action.
	lastboxes	= {}, -- Player near box timeout.
	riding		= {}, -- Players riding boxes.
}

local MP = minetest.get_modpath(minetest.get_current_modname())
dofile(MP .. "/storage.lua")
dofile(MP .. "/register.lua")
dofile(MP .. "/hooks.lua")

-- Player formspecs.
local formspecs = {}

-- Helper function to read unloaded nodes.
local function get_node(pos)
    local node = minetest.get_node_or_nil(pos)
    if node then return node end
    local _,_ = VoxelManip():read_from_map(pos, pos)
    return minetest.get_node_or_nil(pos)
end

local VISUAL_INCREASE = 1.75

-- Cause <sender> to ride <motorhash> beginning at <pos> and targetting <target>.
local function create_box(motorhash, pos, target, sender)
    -- First create the box.
    local obj = minetest.add_entity(pos, "elevator:box")
    obj:setpos(pos)
    -- Attach the player.
    sender:setpos(pos)
    sender:set_attach(obj, "", {x=0, y=9, z=0}, {x=0, y=0, z=0})
    sender:set_eye_offset({x=0, y=-9, z=0},{x=0, y=-9, z=0})
    sender:set_properties({visual_size = {x=VISUAL_INCREASE, y=VISUAL_INCREASE}})
    if armor_path then
        armor:update_player_visuals(sender)
    end
    -- Set the box properties.
    obj:get_luaentity().motor = motorhash
    obj:get_luaentity().uid = math.floor(math.random() * 1000000)
    obj:get_luaentity().attached = sender:get_player_name()
    obj:get_luaentity().start = pos
    obj:get_luaentity().target = target
    obj:get_luaentity().halfway = {x=pos.x, y=(pos.y+target.y)/2, z=pos.z}
    obj:get_luaentity().vmult = (target.y < pos.y) and -1 or 1
    -- Set the speed.
    obj:setvelocity({x=0, y=SPEED*obj:get_luaentity().vmult, z=0})
    obj:setacceleration({x=0, y=ACCEL*obj:get_luaentity().vmult, z=0})
    -- Set the tables.
    elevator.boxes[motorhash] = obj
    elevator.riding[sender:get_player_name()] = {
        motor = motorhash,
        pos = pos,
        target = target,
        box = obj,
    }
    return obj
end

-- Try to teleport player away from any closed (on) elevator node.
elevator.teleport_player_from_elevator = function(player)
    local function solid(pos)
        if not minetest.registered_nodes[minetest.get_node(pos).name] then
            return true
        end
        return minetest.registered_nodes[minetest.get_node(pos).name].walkable
    end
    local pos = vector.round(player:getpos())
    local node = minetest.get_node(pos)
    -- elevator_off is like a shaft, so the player would already be falling.
    if node.name == "elevator:elevator_on" then
        local front = vector.subtract(pos, minetest.facedir_to_dir(node.param2))
        local front_above = vector.add(front, {x=0, y=1, z=0})
        local front_below = vector.subtract(front, {x=0, y=1, z=0})
        -- If the front isn't solid, it's ok to teleport the player.
        if not solid(front) and not solid(front_above) then
            player:setpos(front)
        end
    end
end

local function phash(pos)
    return minetest.pos_to_string(pos)
end

local function punhash(pos)
    return minetest.string_to_pos(pos)
end

-- Starting from <pos>, locate a motor hash.
elevator.locate_motor = function(pos)
    local p = vector.new(pos)
    while true do
        local node = get_node(p)
        if node.name == "elevator:elevator_on" or node.name == "elevator:elevator_off" then
            p.y = p.y + 2
        elseif node.name == "elevator:shaft" then
            p.y = p.y + 1
        elseif node.name == "elevator:motor" then
            return phash(p)
        else
            return nil
        end
    end
end

elevator.build_motor = function(hash)
    local need_saving = false
    local motor = elevator.motors[hash]
    -- Just ignore motors that don't exist.
    if not motor then
        return
    end
    local p = punhash(hash)
    local node = get_node(p)
    -- And ignore motors that aren't motors.
    if node.name ~= "elevator:motor" then
        return
    end
    p.y = p.y - 1
    motor.elevators = {}
    motor.pnames = {}
    motor.labels = {}
    -- Run down through the shaft, storing information about elevators.
    while true do
        local node = get_node(p)
        if node.name == "elevator:shaft" then
            p.y = p.y - 1
        else
            p.y = p.y - 1
            local node = get_node(p)
            if node.name == "elevator:elevator_on" or node.name == "elevator:elevator_off" then
                table.insert(motor.elevators, phash(p))
                table.insert(motor.pnames, tostring(p.y))
                table.insert(motor.labels, "")
                p.y = p.y - 1
                need_saving = true
            else
                break
            end
        end
    end
    -- Set the elevators fully.
    for i,m in ipairs(motor.elevators) do
        local pos = punhash(m)
        local meta = minetest.get_meta(pos)
        meta:set_int("version", VERSION)
        if meta:get_string("motor") ~= hash then
            elevator.build_motor(meta:get_string("motor"))
        end
        motor.labels[i] = meta:get_string("label")
        meta:set_string("motor", hash)
        if motor.labels[i] ~= meta:get_string("infotext") then
            meta:set_string("infotext", motor.labels[i])
        end
    end
    if need_saving then
        elevator.save_elevator()
    end
end

elevator.unbuild = function(pos, add)
    local need_saving = false
    local p = table.copy(pos)
    p.y = p.y - 1
    -- Loop down through the network, set any elevators below this to the off position.
    while true do
        local node = get_node(p)
        if node.name == "elevator:shaft" then
            p.y = p.y - 1
        else
            p.y = p.y - 1
            local node = get_node(p)
            if node.name == "elevator:elevator_on" or node.name == "elevator:elevator_off" then
                local meta = minetest.get_meta(p)
                meta:set_string("motor", "")
                p.y = p.y - 1
            else
                break
            end
        end
    end
    -- After a short delay, build the motor and handle box removal.
    minetest.after(0.01, function(p2, add)
        if not p2 or not add then
            return
        end
        p2.y = p2.y + add
        local motorhash = elevator.locate_motor(p2)
        elevator.build_motor(motorhash)
        -- If there's a box below this point, break it.
        if elevator.boxes[motorhash] and elevator.boxes[motorhash]:getpos() and p2.y >= elevator.boxes[motorhash]:getpos().y then
            elevator.boxes[motorhash] = nil
        end
        -- If the box does not exist, just clear it.
        if elevator.boxes[motorhash] and not elevator.boxes[motorhash]:getpos() then
            elevator.boxes[motorhash] = nil
        end
    end, table.copy(pos), add)
end

minetest.register_node("elevator:motor", {
    description = "Elevator Motor",
    tiles = {
        "default_steel_block.png",
        "default_steel_block.png",
        "elevator_motor.png",
        "elevator_motor.png",
        "elevator_motor.png",
        "elevator_motor.png",
    },
    groups = {cracky=1},
    sounds = default.node_sound_stone_defaults(),
    after_place_node = function(pos, placer, itemstack)
        -- Set up the motor table.
        elevator.motors[phash(pos)] = {
            elevators = {},
            pnames = {},
            labels = {},
        }
        elevator.save_elevator()
        elevator.build_motor(phash(pos))
    end,
    on_destruct = function(pos)
        -- Destroy everything related to this motor.
        elevator.boxes[phash(pos)] = nil
        elevator.motors[phash(pos)] = nil
        elevator.save_elevator()
    end,
})

for _,mode in ipairs({"on", "off"}) do
    local nodename = "elevator:elevator_"..mode
    local on = (mode == "on")
    local box
    local cbox
    if on then
        -- Active elevators have a ceiling and floor.
        box = {

            { 0.48, -0.5,-0.5,  0.5,  1.5, 0.5},
            {-0.5 , -0.5, 0.48, 0.48, 1.5, 0.5},
            {-0.5,  -0.5,-0.5 ,-0.48, 1.5, 0.5},

            { -0.5,-0.5,-0.5,0.5,-0.48, 0.5},
            { -0.5, 1.45,-0.5,0.5, 1.5, 0.5},
        }
        cbox = table.copy(box)
        -- But you can enter them from the top.
        cbox[5] = nil
    else
        -- Inactive elevators are almost like shafts.
        box = {

            { 0.48, -0.5,-0.5,  0.5,  1.5, 0.5},
            {-0.5 , -0.5, 0.48, 0.48, 1.5, 0.5},
            {-0.5,  -0.5,-0.5 ,-0.48, 1.5, 0.5},
            {-0.5 , -0.5, -0.48, 0.5, 1.5, -0.5},
        }
        cbox = box
    end
    minetest.register_node(nodename, {
        description = "Elevator",
        drawtype = "nodebox",
        sunlight_propagates = false,
        paramtype = "light",
        paramtype2 = "facedir",
        on_rotate = screwdriver.disallow,

        selection_box = {
                type = "fixed",
                fixed = box,
        },

        collision_box = {
                type = "fixed",
                fixed = cbox,
        },

        node_box = {
                type = "fixed",
                fixed = box,
        },

        tiles = on and {
                "default_steel_block.png",
                "default_steel_block.png",
                "elevator_box.png",
                "elevator_box.png",
                "elevator_box.png",
                "elevator_box.png",
        } or {
                "elevator_box.png",
                "elevator_box.png",
                "elevator_box.png",
                "elevator_box.png",
                "elevator_box.png",
                "elevator_box.png",
        },
        groups = {cracky=1, choppy=1, snappy=1},
        drop = "elevator:elevator_off",

        -- Emit a bit of light when active.
        light_source = (on and 4 or nil),

        after_place_node  = function(pos, placer, itemstack)
            local meta = minetest.get_meta(pos)
            meta:set_int("version", VERSION)

            -- Add a placeholder to avoid nodes being placed in the top.
            local p = vector.add(pos, {x=0, y=1, z=0})
            local p2 = minetest.dir_to_facedir(placer:get_look_dir())
            minetest.set_node(p, {name="elevator:placeholder", paramtype2="facedir", param2=p2})

            -- Try to build a motor above.
            local motor = elevator.locate_motor(pos)
            if motor then
                elevator.build_motor(motor)
            end
        end,

        after_dig_node = function(pos, node, meta, digger)
            elevator.unbuild(pos, 2)
        end,

        on_place = function(itemstack, placer, pointed_thing)
            local pos  = pointed_thing.above
            local node = minetest.get_node(vector.add(pos, {x=0, y=1, z=0}))
            if (node ~= nil and node.name ~= "air" and node.name ~= "elevator:placeholder") then
                return
            end
            return minetest.item_place(itemstack, placer, pointed_thing)
        end,

        on_rightclick = function(pos, node, sender)
            if not sender or not sender:is_player() then
                return
            end
            local formspec
            local meta = minetest.get_meta(pos)
            formspecs[sender:get_player_name()] = {pos}
            if on then
                if vector.distance(sender:getpos(), pos) > 1 or minetest.get_node(sender:getpos()).name ~= nodename then
                    minetest.chat_send_player(sender:get_player_name(), "You are not inside the booth.")
                    return
                end
                -- Build the formspec from the motor table.
                local tpnames = {}
                local tpnames_l = {}
                local motorhash = meta:get_string("motor")
                local motor = elevator.motors[motorhash]
                for ji,jv in ipairs(motor.pnames) do
                    if tonumber(jv) ~= pos.y then
                        table.insert(tpnames, jv)
                        table.insert(tpnames_l, (motor.labels[ji] and motor.labels[ji] ~= "") and (jv.." - "..minetest.formspec_escape(motor.labels[ji])) or jv)
                    end
                end
                formspecs[sender:get_player_name()] = {pos, tpnames}
                if #tpnames > 0 then
                    if not minetest.is_protected(pos, sender:get_player_name()) then
                        formspec = "size[4,6]"
                        .."label[0,0;Click once to travel.]"
                        .."textlist[-0.1,0.5;4,4;target;"..table.concat(tpnames_l, ",").."]"
                        .."field[0.25,5.25;4,0;label;;"..minetest.formspec_escape(meta:get_string("label")).."]"
                        .."button_exit[-0.05,5.5;4,1;setlabel;Set label]"
                    else
                        formspec = "size[4,4.4]"
                        .."label[0,0;Click once to travel.]"
                        .."textlist[-0.1,0.5;4,4;target;"..table.concat(tpnames_l, ",").."]"
                    end
                else
                    if not minetest.is_protected(pos, sender:get_player_name()) then
                        formspec = "size[4,2]"
                        .."label[0,0;No targets available.]"
                        .."field[0.25,1.25;4,0;label;;"..minetest.formspec_escape(meta:get_string("label")).."]"
                        .."button_exit[-0.05,1.5;4,1;setlabel;Set label]"
                    else
                        formspec = "size[4,0.4]"
                        .."label[0,0;No targets available.]"
                    end
                end
                minetest.show_formspec(sender:get_player_name(), "elevator:elevator", formspec)
            elseif not elevator.motors[meta:get_string("motor")] then
                if not minetest.is_protected(pos, sender:get_player_name()) then
                    formspec = "size[4,2]"
                    .."label[0,0;This elevator is inactive.]"
                    .."field[0.25,1.25;4,0;label;;"..minetest.formspec_escape(meta:get_string("label")).."]"
                    .."button_exit[-0.05,1.5;4,1;setlabel;Set label]"
                else
                    formspec = "size[4,0.4]"
                    .."label[0,0;This elevator is inactive.]"
                end
                minetest.show_formspec(sender:get_player_name(), "elevator:elevator", formspec)
            elseif elevator.boxes[meta:get_string("motor")] then
                if not minetest.is_protected(pos, sender:get_player_name()) then
                    formspec = "size[4,2]"
                    .."label[0,0;This elevator is in use.]"
                    .."field[0.25,1.25;4,0;label;;"..minetest.formspec_escape(meta:get_string("label")).."]"
                    .."button_exit[-0.05,1.5;4,1;setlabel;Set label]"
                else
                    formspec = "size[4,0.4]"
                    .."label[0,0;This elevator is in use.]"
                end
                minetest.show_formspec(sender:get_player_name(), "elevator:elevator", formspec)
            end
        end,

        on_destruct = function(pos)
            local p = vector.add(pos, {x=0, y=1, z=0})
            if get_node(p).name == "elevator:placeholder" then
                minetest.remove_node(p)
            end
        end,
    })
end

minetest.register_on_player_receive_fields(function(sender, formname, fields)
    if formname ~= "elevator:elevator" then
        return
    end
    local pos = formspecs[sender:get_player_name()] and formspecs[sender:get_player_name()][1] or nil
    if not pos then
        return true
    end
    local meta = minetest.get_meta(pos)
    if fields.setlabel then
        if minetest.is_protected(pos, sender:get_player_name()) then
            return true
        end
        meta:set_string("label", fields.label)
        meta:set_string("infotext", fields.label)
        -- Rebuild the elevator shaft so the other elevators can read this label.
        local motorhash = meta:get_string("motor")
        elevator.build_motor(elevator.motors[motorhash] and motorhash or elevator.locate_motor(pos))
        return true
    end
    -- Double check if it's ok to go.
    if vector.distance(sender:getpos(), pos) > 1 then
        return true
    end
    if fields.target then
        local closeformspec = ""
        -- HACK: With player information extensions enabled, we can check if closing formspecs are now allowed. This is specifically used on Survival in Ethereal.
        local pi = minetest.get_player_information(sender:get_player_name())
        if (not (pi.major == 0 and pi.minor == 4 and pi.patch == 15)) and (pi.protocol_version or 29) < 29 then
            closeformspec = "size[4,2] label[0,0;You are now using the elevator.\nUpgrade Minetest to avoid this dialog.] button_exit[0,1;4,1;close;Close]"
        end
        -- End hacky HACK.
        minetest.after(0.2, minetest.show_formspec, sender:get_player_name(), "elevator:elevator", closeformspec)
        -- Ensure we're connected to a motor.
        local motorhash = meta:get_string("motor")
        local motor = elevator.motors[motorhash]
        if not motor then
            motorhash = elevator.locate_motor(pos)
            motor = elevator.motors[motorhash]
            if motor then
                meta:set_string("motor", "")
                elevator.build_motor(motorhash)
                minetest.chat_send_player(sender:get_player_name(), "Recalibrated to a new motor, please try again.")
                return true
            end
        end
        if not motor then
            minetest.chat_send_player(sender:get_player_name(), "This elevator is not attached to a motor.")
            return true
        end
        if not formspecs[sender:get_player_name()][2] or not formspecs[sender:get_player_name()][2][minetest.explode_textlist_event(fields.target).index] then
            return true
        end
        -- Locate our target elevator.
        local target = nil
        local selected_target = formspecs[sender:get_player_name()][2][minetest.explode_textlist_event(fields.target).index]
        for i,v in ipairs(motor.pnames) do
            if v == selected_target then
                target = punhash(motor.elevators[i])
            end
        end
        -- Found the elevator? Then go!
        if target then
            -- Final check.
            if elevator.boxes[motorhash] then
                minetest.chat_send_player(sender:get_player_name(), "This elevator is in use.")
                return true
            end
            local obj = create_box(motorhash, pos, target, sender)
            -- Teleport anyone standing within an on elevator out, or they'd fall through the off elevators.
            for _,p in ipairs(motor.elevators) do
                local p = punhash(p)
                for _,object in ipairs(minetest.get_objects_inside_radius(p, 0.6)) do
                    if object.is_player and object:is_player() then
                        if object:get_player_name() ~= obj:get_luaentity().attached then
                            elevator.teleport_player_from_elevator(object)
                        end
                    end
                end
            end
        else
            minetest.chat_send_player(sender:get_player_name(), "This target is invalid.")
            return true
        end
        return true
    end
    return true
end)

-- Compatability with an older version.
minetest.register_alias("elevator:elevator", "elevator:elevator_off")

-- Ensure an elevator is up to the latest version.
local function upgrade_elevator(pos, meta)
    if meta:get_int("version") ~= VERSION then
        minetest.log("action", "[elevator] Updating elevator with old version at "..minetest.pos_to_string(pos))
        minetest.after(0, function(pos) elevator.build_motor(elevator.locate_motor(pos)) end, pos)
        meta:set_int("version", VERSION)
        meta:set_string("formspec", "")
        meta:set_string("infotext", meta:get_string("label"))
    end
end

-- Convert off to on when applicable.
local offabm = function(pos, node)
    local meta = minetest.get_meta(pos)
    upgrade_elevator(pos, meta)
    if not elevator.boxes[meta:get_string("motor")] and elevator.motors[meta:get_string("motor")] then
        node.name = "elevator:elevator_on"
        minetest.swap_node(pos, node)
    end
end

minetest.register_abm({
    nodenames = {"elevator:elevator_off"},
    interval = 1,
    chance = 1,
    action = offabm,
    label = "Elevator (Off)",
})

-- Convert on to off when applicable.
minetest.register_abm({
    nodenames = {"elevator:elevator_on"},
    interval = 1,
    chance = 1,
    action = function(pos, node)
        local meta = minetest.get_meta(pos)
        upgrade_elevator(pos, meta)
        if elevator.boxes[meta:get_string("motor")] or not elevator.motors[meta:get_string("motor")] then
            node.name = "elevator:elevator_off"
            minetest.swap_node(pos, node)
        end
    end,
    label = "Elevator (On)",
})

-- Remove the player from self, and teleport them to pos if specified.
local function detach(self, pos)
    local player = minetest.get_player_by_name(self.attached)
    local attached = player:get_attach()
    if not attached or attached:get_luaentity().uid ~= self.uid then
        return
    end
    player:set_detach()
    player:set_eye_offset({x=0, y=0, z=0},{x=0, y=0, z=0})
    player:set_properties({visual_size = {x=1, y=1}})
    if armor_path then
        armor:update_player_visuals(player)
    end
    if pos then
        player:setpos(pos)
	minetest.after(0.1, function(pl, p)
		pl:setpos(p)
	end, player, pos)
    end
    elevator.riding[self.attached] = nil
end

local box_entity = {
    physical = false,
    collisionbox = {0,0,0,0,0,0},
    visual = "wielditem",
    visual_size = {x=1, y=1},
    textures = {"elevator:elevator_box"},

    attached = "",
    motor = false,
    target = false,

    start = false,
    lastpos = false,
    halfway = false,
    vmult = 0,

    on_activate = function(self, staticdata)
        -- Don't want the box being destroyed by anything except the elevator system.
        self.object:set_armor_groups({immortal=1})
    end,

    on_step = function(self, dtime)
        local pos = self.object:getpos()
        -- First, check if this box needs removed.
        -- If the motor has a box and it isn't this box.
        if elevator.boxes[self.motor] and elevator.boxes[self.motor] ~= self.object then
            minetest.log("action", "[elevator] "..minetest.pos_to_string(pos).." broke due to duplication.")
            self.object:remove()
            return
        end
        -- If our attached player can't be found.
        if not minetest.get_player_by_name(self.attached) then
            minetest.log("action", "[elevator] "..minetest.pos_to_string(pos).." broke due to lack of attachee logged in.")
            self.object:remove()
            elevator.boxes[self.motor] = nil
            return
        end
        -- If our attached player is no longer with us.
        if not minetest.get_player_by_name(self.attached):get_attach() or minetest.get_player_by_name(self.attached):get_attach():get_luaentity().uid ~= self.uid then
            minetest.log("action", "[elevator] "..minetest.pos_to_string(pos).." broke due to lack of attachee.")
            self.object:remove()
            elevator.boxes[self.motor] = nil
            return
        end
        -- If our motor's box is nil, we should self-destruct.
        if not elevator.boxes[self.motor] then
            minetest.log("action", "[elevator] "..minetest.pos_to_string(pos).." broke due to nil entry in boxes.")
            detach(self)
            self.object:remove()
            elevator.boxes[self.motor] = nil
            return
        end

        minetest.get_player_by_name(self.attached):setpos(pos)
        -- Ensure lastpos is set to something.
        self.lastpos = self.lastpos or pos

        -- Loop through all travelled nodes.
        for y=self.lastpos.y,pos.y,((self.lastpos.y > pos.y) and -0.3 or 0.3) do
            local p = vector.round({x=pos.x, y=y, z=pos.z})
            local node = get_node(p)
            if node.name == "elevator:shaft" then
                -- Nothing, just continue on our way.
            elseif node.name == "elevator:elevator_on" or node.name == "elevator:elevator_off" then
                -- If this is our target, detach the player here, destroy this box, and update the target elevator without waiting for the abm.
                if vector.distance(p, self.target) < 1 then
                    minetest.log("action", "[elevator] "..minetest.pos_to_string(p).." broke due to arrival.")
                    detach(self, vector.add(self.target, {x=0, y=-0.4, z=0}))
                    self.object:remove()
                    elevator.boxes[self.motor] = nil
                    offabm(self.target, node)
                    return
                end
            else
                -- Check if we're in the top part of an elevator, if so it's fine.
                local below = vector.add(p, {x=0,y=-1,z=0})
                local belownode = get_node(below)
                if belownode.name ~= "elevator:elevator_on" and belownode.name ~= "elevator:elevator_off" then
                    -- If we aren't, then break the box.
                    minetest.log("action", "[elevator] "..minetest.pos_to_string(p).." broke on "..node.name)
                    elevator.boxes[self.motor] = nil
                    detach(self, p)
                    self.object:remove()
                    return
                end
            end
        end
        self.lastpos = pos
    end,
}

minetest.register_entity("elevator:box", box_entity)
