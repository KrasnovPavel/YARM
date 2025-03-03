require "util"
require "libs/array_pair"
require "libs/ore_tracker"
local mod_gui = require("mod-gui")
local v = require "semver"

local mod_version = "0.10.14"

-- Sanity: site names aren't allowed to be longer than this, to prevent them
-- kicking the buttons off the right edge of the screen
local MAX_SITE_NAME_LENGTH = 50

resmon = {
    on_click = {},
    endless_resources = {},
    filters = {},

    -- updated `on_tick` to contain `ore_tracker.get_entity_cache()`
    entity_cache = nil,
}

function string.starts_with(haystack, needle)
    return string.sub(haystack, 1, string.len(needle)) == needle
end

function string.ends_with(haystack, needle)
    return string.sub(haystack, -string.len(needle)) == needle
end

function resmon.init_globals()
    for index, _ in pairs(game.players) do
        resmon.init_player(index)
    end
end

function resmon.on_player_created(event)
    resmon.init_player(event.player_index)
end

-- migration v0.8.0: remove remote viewers and put players back into the right entity if available
local function migrate_remove_remote_viewer(player, player_data)
    local real_char = player_data.real_character
    if not real_char or not real_char.valid then
        player.print { "YARM-warn-no-return-possible" }
        return
    end

    player.character = real_char
    if player_data.remote_viewer and player_data.remote_viewer.valid then
        player_data.remote_viewer.destroy()
    end

    player_data.real_character = nil
    player_data.remote_viewer = nil
    player_data.viewing_site = nil
end


local function migrate_remove_minimum_resource_amount(force_data)
    for _, site in pairs(force_data.ore_sites) do
        if site.minimum_resource_amount then site.minimum_resource_amount = nil end
    end
end


function resmon.init_player(player_index)
    local player = game.players[player_index]
    resmon.init_force(player.force)

    -- migration v0.7.402: YARM_root now in mod_gui, destroy the old one
    local old_root = player.gui.left.YARM_root
    if old_root and old_root.valid then old_root.destroy() end

    local root = mod_gui.get_frame_flow(player).YARM_root
    if root and root.buttons and (
        -- migration v0.8.0: expando now a set of filter buttons, destroy the root and recreate later
            root.buttons.YARM_expando
            -- migration v0.TBD: add toggle bg button
            or not root.buttons.YARM_toggle_bg
            or not root.buttons.YARM_toggle_surfacesplit
            or not root.buttons.YARM_toggle_lite)
    then
        root.destroy()
    end

    if not global.player_data then global.player_data = {} end

    local player_data = global.player_data[player_index]
    if not player_data then player_data = {} end

    if not player_data.gui_update_ticks or player_data.gui_update_ticks == 60 then player_data.gui_update_ticks = 300 end

    if not player_data.overlays then player_data.overlays = {} end

    if player_data.viewing_site then migrate_remove_remote_viewer(player, player_data) end

    global.player_data[player_index] = player_data
end

function resmon.init_force(force)
    if not global.force_data then global.force_data = {} end

    local force_data = global.force_data[force.name]
    if not force_data then force_data = {} end

    if not force_data.ore_sites then
        force_data.ore_sites = {}
    else
        resmon.migrate_ore_sites(force_data)
        resmon.migrate_ore_entities(force_data)

        resmon.sanity_check_sites(force, force_data)
    end

    migrate_remove_minimum_resource_amount(force_data)

    global.force_data[force.name] = force_data
end

local function table_contains(haystack, needle)
    for _, candidate in pairs(haystack) do
        if candidate == needle then
            return true
        end
    end

    return false
end


function resmon.sanity_check_sites(force, force_data)
    local discarded_sites = {}
    local missing_ores = {}

    for name, site in pairs(force_data.ore_sites) do
        local entity_prototype = game.entity_prototypes[site.ore_type]
        if not entity_prototype or not entity_prototype.valid then
            discarded_sites[#discarded_sites + 1] = name
            if not table_contains(missing_ores, site.ore_type) then
                missing_ores[#missing_ores + 1] = site.ore_type
            end

            if site.chart_tag and site.chart_tag.valid then
                site.chart_tag.destroy()
            end
            force_data.ore_sites[name] = nil
        end
    end

    if #discarded_sites == 0 then return end

    local discard_message = "YARM-warnings.discard-multi-missing-ore-type-multi"
    if #missing_ores == 1 then
        discard_message = "YARM-warnings.discard-multi-missing-ore-type-single"
        if #discarded_sites == 1 then
            discard_message = "YARM-warnings.discard-single-missing-ore-type-single"
        end
    end

    force.print { discard_message, table.concat(discarded_sites, ', '), table.concat(missing_ores, ', ') }
    log { "", force.name, ' was warned: ', { discard_message, table.concat(discarded_sites, ', '),
        table.concat(missing_ores, ', ') } }
end

local function position_to_string(entity)
    -- scale it up so (hopefully) any floating point component disappears,
    -- then force it to be an integer with %d.  not using util.positiontostr
    -- as it uses %g and keeps the floating point component.
    return string.format("%d,%d", entity.x * 100, entity.y * 100)
end


function resmon.migrate_ore_entities(force_data)
    for name, site in pairs(force_data.ore_sites) do
        -- v0.7.15: instead of tracking entities, track their positions and
        -- re-find the entity when needed.
        if site.known_positions then
            site.known_positions = nil
        end
        if site.entities then
            site.entity_positions = array_pair.new()
            for _, ent in pairs(site.entities) do
                if ent.valid then
                    array_pair.insert(site.entity_positions, ent.position)
                end
            end
            site.entities = nil
        end

        -- v0.7.107: change to using the site position as a table key, to
        -- allow faster searching for already-added entities.
        if site.entity_positions then
            site.entity_table = {}
            site.entity_count = 0
            local iter = array_pair.iterator(site.entity_positions)
            while iter.has_next() do
                pos = iter.next()
                local key = position_to_string(pos)
                site.entity_table[key] = pos
                site.entity_count = site.entity_count + 1
            end
            site.entity_positions = nil
        end

        -- v0.8.6: The entities are now tracked by the ore_tracker, and
        -- sites need only maintain ore tracker indices.
        if site.entity_table then
            site.tracker_indices = {}
            site.entity_count = 0

            for _, pos in pairs(site.entity_table) do
                local ent = site.surface.find_entity(site.ore_type, pos)

                if ent and ent.valid then
                    local index = ore_tracker.add_entity(ent)
                    site.tracker_indices[index] = true
                    site.entity_count = site.entity_count + 1
                end
            end

            site.entity_table = nil
        end
    end
end

function resmon.migrate_ore_sites(force_data)
    for name, site in pairs(force_data.ore_sites) do
        if not site.remaining_permille then
            site.remaining_permille = math.floor(site.amount * 1000 / site.initial_amount)
        end
        if not site.ore_per_minute then site.ore_per_minute = 0 end
        if not site.scanned_ore_per_minute then site.scanned_ore_per_minute = 0 end
        if not site.lifetime_ore_per_minute then site.lifetime_ore_per_minute = 0 end
        if not site.etd_minutes then site.etd_minutes = 1 / 0 end
        if not site.scanned_etd_minutes then site.scanned_etd_minutes = -1 end
        if not site.lifetime_etd_minutes then site.lifetime_etd_minutes = 1 / 0 end
        if not site.etd_is_lifetime then site.etd_is_lifetime = 1 end
        if not site.etd_minutes_delta then site.etd_minutes_delta = 0 end
        if not site.ore_per_minute_delta then site.ore_per_minute_delta = 0 end
    end
end

local function find_resource_at(surface, position)
    -- The position we get is centered in its tile (e.g., {8.5, 17.5}).
    -- Sometimes, the resource does not cover the center, so search the full tile.
    local top_left = { x = position.x - 0.5, y = position.y - 0.5 }
    local bottom_right = { x = position.x + 0.5, y = position.y + 0.5 }

    local stuff = surface.find_entities_filtered { area = { top_left, bottom_right }, type = 'resource' }
    if #stuff < 1 then return nil end

    return stuff[1] -- there should never be another resource at the exact same coordinates
end


local function find_center(area)
    local xpos = (area.left + area.right) / 2
    local ypos = (area.top + area.bottom) / 2
    return { x = xpos, y = ypos }
end


local function find_center_tile(area)
    local center = find_center(area)
    return { x = math.floor(center.x), y = math.floor(center.y) }
end


function resmon.on_player_selected_area(event)
    if event.item ~= 'yarm-selector-tool' then return end

    local player_data = global.player_data[event.player_index]
    local entities = event.entities

    if #entities < 1 then
        entities = { find_resource_at(event.surface, {
            x = 0.5 + math.floor((event.area.left_top.x + event.area.right_bottom.x) / 2),
            y = 0.5 + math.floor((event.area.left_top.y + event.area.right_bottom.y) / 2)
        }) }
    end

    if #entities < 1 then
        -- if we have an expanding site, submit it. else, just drop the current site
        if player_data.current_site and player_data.current_site.is_site_expanding then
            resmon.submit_site(event.player_index)
        else
            resmon.clear_current_site(event.player_index)
        end
        return
    end

    local entities_by_type = {}
    for _, entity in pairs(entities) do
        if entity.prototype.type == 'resource' then
            entities_by_type[entity.name] = entities_by_type[entity.name] or {}
            table.insert(entities_by_type[entity.name], entity)
        end
    end

    player_data.todo = player_data.todo or {}
    for _, group in pairs(entities_by_type) do table.insert(player_data.todo, group) end
    -- note: resmon.update_players() (via on_tick) will continue the operation from here
end

function resmon.clear_current_site(player_index)
    local player = game.players[player_index]
    local player_data = global.player_data[player_index]

    player_data.current_site = nil

    while #player_data.overlays > 0 do
        table.remove(player_data.overlays).destroy()
    end
end

function resmon.add_resource(player_index, entity)
    if not entity.valid then return end
    local player = game.players[player_index]
    local player_data = global.player_data[player_index]

    if player_data.current_site and player_data.current_site.ore_type ~= entity.name then
        if player_data.current_site.finalizing then
            resmon.submit_site(player_index)
        else
            resmon.clear_current_site(player_index)
        end
    end

    if not player_data.current_site then
        player_data.current_site = {
            added_at = game.tick,
            surface = entity.surface,
            force = player.force,
            ore_type = entity.name,
            ore_name = entity.prototype.localised_name,
            tracker_indices = {},
            entity_count = 0,
            initial_amount = 0,
            amount = 0,
            extents = {
                left = entity.position.x,
                right = entity.position.x,
                top = entity.position.y,
                bottom = entity.position.y,
            },
            next_to_scan = {},
            entities_to_be_overlaid = {},
            next_to_overlay = {},
            etd_minutes = -1,
            scanned_etd_minutes = -1,
            lifetime_etd_minutes = -1,
            ore_per_minute = -1,
            scanned_ore_per_minute = -1,
            lifetime_ore_per_minute = -1,
            etd_is_lifetime = 1,
            last_ore_check = nil,       -- used for ETD easing; initialized when needed,
            last_modified_amount = nil, -- but I wanted to _show_ that they can exist.
            etd_minutes_delta = 0,
            ore_per_minute_delta = 0,
        }
    end


    if player_data.current_site.is_site_expanding then
        player_data.current_site.has_expanded = true -- relevant for the console output
        if not player_data.current_site.original_amount then
            player_data.current_site.original_amount = player_data.current_site.amount
        end
    end

    resmon.add_single_entity(player_index, entity)
    -- note: resmon.scan_current_site() (via on_tick) will continue the operation from here
end

function resmon.add_single_entity(player_index, entity)
    local player_data = global.player_data[player_index]
    local site = player_data.current_site
    local tracker_index = ore_tracker.add_entity(entity)

    -- Don't re-add the same entity multiple times
    if site.tracker_indices[tracker_index] then return end

    -- Reset the finalizing timer
    if site.finalizing then site.finalizing = false end

    -- Memorize this entity
    site.tracker_indices[tracker_index] = true
    site.entity_count = site.entity_count + 1
    table.insert(site.next_to_scan, entity)
    site.amount = site.amount + entity.amount

    -- Resize the site bounds if necessary
    if entity.position.x < site.extents.left then
        site.extents.left = entity.position.x
    elseif entity.position.x > site.extents.right then
        site.extents.right = entity.position.x
    end
    if entity.position.y < site.extents.top then
        site.extents.top = entity.position.y
    elseif entity.position.y > site.extents.bottom then
        site.extents.bottom = entity.position.y
    end

    -- Give visible feedback, too
    resmon.put_marker_at(entity.surface, entity.position, player_data)
end

function resmon.put_marker_at(surface, pos, player_data)
    if math.floor(pos.x) % settings.global["YARM-overlay-step"].value ~= 0 or
        math.floor(pos.y) % settings.global["YARM-overlay-step"].value ~= 0 then
        return
    end

    local overlay = surface.create_entity { name = "rm_overlay",
        force = game.forces.neutral,
        position = pos }
    overlay.minable = false
    overlay.destructible = false
    overlay.operable = false
    table.insert(player_data.overlays, overlay)
end

local function shift_position(position, direction)
    if direction == defines.direction.north then
        return { x = position.x, y = position.y - 1 }
    elseif direction == defines.direction.northeast then
        return { x = position.x + 1, y = position.y - 1 }
    elseif direction == defines.direction.east then
        return { x = position.x + 1, y = position.y }
    elseif direction == defines.direction.southeast then
        return { x = position.x + 1, y = position.y + 1 }
    elseif direction == defines.direction.south then
        return { x = position.x, y = position.y + 1 }
    elseif direction == defines.direction.southwest then
        return { x = position.x - 1, y = position.y + 1 }
    elseif direction == defines.direction.west then
        return { x = position.x - 1, y = position.y }
    elseif direction == defines.direction.northwest then
        return { x = position.x - 1, y = position.y - 1 }
    else
        return position
    end
end


function resmon.scan_current_site(player_index)
    local site = global.player_data[player_index].current_site

    local to_scan = math.min(30, #site.next_to_scan)
    local max_dist = settings.global["YARM-grow-limit"].value
    for i = 1, to_scan do
        local entity = table.remove(site.next_to_scan, 1)
        local entity_position = entity.position
        local surface = entity.surface
        site.first_center = site.first_center or find_center(site.extents)

        -- Look in every direction around this entity...
        for _, dir in pairs(defines.direction) do
            -- ...and if there's a resource, add it
            local search_pos = shift_position(entity_position, dir)
            if max_dist < 0 or util.distance(search_pos, site.first_center) < max_dist then
                local found = find_resource_at(surface, search_pos)
                if found and found.name == site.ore_type then
                    resmon.add_single_entity(player_index, found)
                end
            end
        end
    end
end

local function format_number(n) -- credit http://richard.warburton.it
    local left, num, right = string.match(n, '^([^%d]*%d)(%d*)(.-)$')
    return left .. (num:reverse():gsub('(%d%d%d)', '%1,'):reverse()) .. right
end


local si_prefixes = { '', ' k', ' M', ' G' }

local function format_number_si(n)
    for i = 1, #si_prefixes do
        if n < 1000 then
            return string.format('%d%s', n, si_prefixes[i])
        end
        n = math.floor(n / 1000)
    end

    -- 1,234 T resources? I guess we should support it...
    return string.format('%s T', format_number(n))
end


local octant_names = {
    [0] = "E",
    [1] = "SE",
    [2] = "S",
    [3] = "SW",
    [4] = "W",
    [5] = "NW",
    [6] = "N",
    [7] = "NE",
}

local function get_octant_name(vector)
    local radians = math.atan2(vector.y, vector.x)
    local octant = math.floor(8 * radians / (2 * math.pi) + 8.5) % 8

    return octant_names[octant]
end


function resmon.finalize_site(player_index)
    local player = game.players[player_index]
    local player_data = global.player_data[player_index]

    local site = player_data.current_site
    site.finalizing = true
    site.finalizing_since = game.tick
    site.initial_amount = site.amount
    site.ore_per_minute = 0
    site.remaining_permille = 1000

    site.center = find_center_tile(site.extents)

    --[[ don't rename a site we've expanded! (if the site name changes it'll create a new site
         instead of replacing the existing one) ]]
    if not site.is_site_expanding then
        site.name = string.format("%s %d", get_octant_name(site.center), util.distance({ x = 0, y = 0 }, site.center))
        if settings.global["YARM-site-prefix-with-surface"].value then
            site.name = string.format("%s %s", site.surface.name, site.name)
        end
    end

    resmon.count_deposits(site, site.added_at % settings.global["YARM-ticks-between-checks"].value)
end

function resmon.update_chart_tag(site)
    local is_chart_tag_enabled = settings.global["YARM-map-markers"].value

    if not is_chart_tag_enabled then
        if site.chart_tag and site.chart_tag.valid then
            -- chart tags were just disabled, so remove them from the world
            site.chart_tag.destroy()
            site.chart_tag = nil
        end
        return
    end

    if not site.chart_tag or not site.chart_tag.valid then
        if not site.force or not site.force.valid or not site.surface.valid then return end

        local chart_tag = {
            position = site.center,
            text = site.name,
        }
        site.chart_tag = site.force.add_chart_tag(site.surface, chart_tag)
        if not site.chart_tag then return end -- may fail if chunk is not currently charted accd. to @Bilka
    end

    local display_value = resmon.generate_display_site_amount(site, nil, 1)
    local prototype = game.entity_prototypes[site.ore_type]
    site.chart_tag.text =
        string.format('%s - %s %s', site.name, display_value, resmon.get_rich_text_for_products(prototype))
    return
end

function resmon.generate_display_site_amount(site, player, short)
    local format_func = short and format_number_si or format_number
    local entity_prototype = game.entity_prototypes[site.ore_type]
    if resmon.is_endless_resource(site.ore_type, entity_prototype) then
        local normal_site_amount = entity_prototype.normal_resource_amount * site.entity_count
        local val = (normal_site_amount == 0 and 0) or (100 * site.amount / normal_site_amount)
        return site.entity_count .. " x " .. format_number(string.format("%.1f%%", val))
    end

    local amount_display = format_func(site.amount)
    if not settings.global["YARM-adjust-for-productivity"].value then return amount_display end

    local amount_prod_display =
        format_func(math.floor(site.amount * (1 + (player or site).force.mining_drill_productivity_bonus)))

    if not settings.global["YARM-productivity-show-raw-and-adjusted"].value then
        return amount_prod_display
    elseif settings.global["YARM-productivity-parentheses-part-is"].value == "adjusted" then
        return string.format("%s (%s)", amount_display, amount_prod_display)
    else
        return string.format("%s (%s)", amount_prod_display, amount_display)
    end
end

function resmon.get_rich_text_for_products(proto)
    if not proto or not proto.mineable_properties or not proto.mineable_properties.products then
        return '' -- only supporting resource entities...
    end

    local result = ''
    for _, product in pairs(proto.mineable_properties.products) do
        result = result .. string.format('[%s=%s]', product.type, product.name)
    end

    return result
end

function resmon.submit_site(player_index)
    local player = game.players[player_index]
    local player_data = global.player_data[player_index]
    local force_data = global.force_data[player.force.name]
    local site = player_data.current_site

    force_data.ore_sites[site.name] = site
    resmon.clear_current_site(player_index)
    if (site.is_site_expanding) then
        if (site.has_expanded) then
            -- reset statistics, the site didn't actually just grow a bunch of ore in existing tiles
            site.last_ore_check = nil
            site.last_modified_amount = nil

            local amount_added = site.amount - site.original_amount
            local sign = amount_added < 0 and '' or '+' -- format_number will handle the negative sign for us (if needed)
            player.print { "YARM-site-expanded", site.name, format_number(site.amount), site.ore_name,
                sign .. format_number(amount_added) }
        end
        --[[ NB: deliberately not outputting anything in the case where the player cancelled (or
             timed out) a site expansion without expanding anything (to avoid console spam) ]]

        if site.chart_tag and site.chart_tag.valid then
            site.chart_tag.destroy()
        end
    else
        player.print { "YARM-site-submitted", site.name, format_number(site.amount), site.ore_name }
    end
    resmon.update_chart_tag(site)

    -- clear site expanding state so we can re-expand the same site again (and get sensible numbers!)
    if (site.is_site_expanding) then
        site.is_site_expanding = nil
        site.has_expanded = nil
        site.original_amount = nil
    end
    resmon.update_force_members_ui(player)
end

function resmon.is_endless_resource(ent_name, proto)
    if resmon.endless_resources[ent_name] ~= nil then
        return resmon.endless_resources[ent_name]
    end

    if not proto then return false end

    if proto.infinite_resource then
        resmon.endless_resources[ent_name] = true
    else
        resmon.endless_resources[ent_name] = false
    end

    return resmon.endless_resources[ent_name]
end

function resmon.count_deposits(site, update_cycle)
    if site.iter_fn then
        resmon.tick_deposit_count(site)
        return
    end

    local site_update_cycle = site.added_at % settings.global["YARM-ticks-between-checks"].value
    if site_update_cycle ~= update_cycle then
        return
    end

    site.iter_fn, site.iter_state, site.iter_key = pairs(site.tracker_indices)
    site.update_amount = 0
end

function resmon.tick_deposit_count(site)
    local index = site.iter_key

    for _ = 1, 1000 do
        index = site.iter_fn(site.iter_state, index)
        if index == nil then
            resmon.finish_deposit_count(site)
            return
        end

        local tracking_data = resmon.entity_cache[index]
        if tracking_data and tracking_data.valid then
            site.update_amount = site.update_amount + tracking_data.resource_amount
        else
            site.tracker_indices[index] = nil -- It's permitted to delete from a table being iterated
            site.entity_count = site.entity_count - 1
        end
    end
    site.iter_key = index
end

-- as a default case, takes a diff between two values and returns a smoothed
-- easing step. however to force convergence, it does *not* smooth diffs below 1
-- and clamps smoothed diffs below 10 to be at least 1.
function resmon.smooth_clamp_diff(diff)
    if math.abs(diff) < 1 then
        return diff
    elseif math.abs(diff) < 10 then
        return math.abs(diff) / diff
    end

    return 0.1 * diff
end

function resmon.finish_deposit_count(site)
    site.iter_key = nil
    site.iter_fn = nil
    site.iter_state = nil

    if site.last_ore_check then
        if not site.last_modified_amount then             -- make sure those two values have a default
            site.last_modified_amount = site.amount       --
            site.last_modified_tick = site.last_ore_check --
        end
        local delta_ore_since_last_update = site.last_modified_amount - site.amount
        if delta_ore_since_last_update ~= 0 then                                                     -- only store the amount and tick from last update if it actually changed
            site.last_modified_tick = site.last_ore_check                                            --
            site.last_modified_amount = site.amount                                                  --
        end
        local delta_ore_since_last_change = (site.update_amount - site.last_modified_amount)         -- use final amount and tick to calculate
        local delta_ticks = game.tick - site.last_modified_tick                                      --
        local new_ore_per_minute = (delta_ore_since_last_change * 3600 / delta_ticks)                -- ease the per minute value over time
        local diff_step = resmon.smooth_clamp_diff(new_ore_per_minute - site.scanned_ore_per_minute) --
        site.scanned_ore_per_minute = site.scanned_ore_per_minute + diff_step                        --
    end

    local entity_prototype = game.entity_prototypes[site.ore_type]
    local is_endless = resmon.is_endless_resource(site.ore_type, entity_prototype)
    local minimum = is_endless and (site.entity_count * entity_prototype.minimum_resource_amount) or 0
    local amount_left = site.amount - minimum

    site.scanned_etd_minutes =
        (site.scanned_ore_per_minute ~= 0 and amount_left / (-site.scanned_ore_per_minute))
        or (amount_left == 0 and 0)
        or -1

    site.amount = site.update_amount
    amount_left = site.amount - minimum
    site.amount_left = amount_left
    if settings.global["YARM-adjust-over-percentage-sites"].value then
        site.initial_amount = math.max(site.initial_amount, site.amount)
    end
    site.last_ore_check = game.tick

    site.remaining_permille = resmon.calc_remaining_permille(site)

    local age_minutes = (game.tick - site.added_at) / 3600
    local depleted = site.initial_amount - site.amount
    site.lifetime_ore_per_minute = -depleted / age_minutes
    site.lifetime_etd_minutes =
        (site.lifetime_ore_per_minute ~= 0 and amount_left / (-site.lifetime_ore_per_minute))
        or (amount_left == 0 and 0)
        or -1

    local old_etd_minutes = site.etd_minutes
    local old_ore_per_minute = site.ore_per_minute
    if site.scanned_etd_minutes == -1 or site.lifetime_etd_minutes <= site.scanned_etd_minutes then
        site.ore_per_minute = site.lifetime_ore_per_minute
        site.etd_minutes = site.lifetime_etd_minutes
        site.etd_is_lifetime = 1
    else
        site.ore_per_minute = site.scanned_ore_per_minute
        site.etd_minutes = site.scanned_etd_minutes
        site.etd_is_lifetime = 0
    end
    site.etd_minutes_delta = site.etd_minutes - old_etd_minutes
    site.ore_per_minute_delta = site.ore_per_minute - old_ore_per_minute

    -- these are just to prevent errant NaNs
    site.etd_minutes_delta = (site.etd_minutes_delta ~= site.etd_minutes_delta) and 0 or site.etd_minutes_delta
    site.ore_per_minute_delta =
        (site.ore_per_minute_delta ~= site.ore_per_minute_delta) and 0 or site.ore_per_minute_delta

    resmon.update_chart_tag(site)

    script.raise_event(on_site_updated, {
        force_name         = site.force.name,
        site_name          = site.name,
        amount             = site.amount,
        ore_per_minute     = site.ore_per_minute,
        remaining_permille = site.remaining_permille,
        ore_type           = site.ore_type,
        etd_minutes        = site.etd_minutes,
    })
end

function resmon.calc_remaining_permille(site)
    local entity_prototype = game.entity_prototypes[site.ore_type]
    local minimum = resmon.is_endless_resource(site.ore_type, entity_prototype)
        and (site.entity_count * entity_prototype.minimum_resource_amount) or 0
    local amount_left = site.amount - minimum
    local initial_amount_available = site.initial_amount - minimum
    return initial_amount_available <= 0 and 0 or math.floor(amount_left * 1000 / initial_amount_available)
end

local function site_comparator_default(left, right)
    if left.remaining_permille ~= right.remaining_permille then
        return left.remaining_permille < right.remaining_permille
    elseif left.added_at ~= right.added_at then
        return left.added_at < right.added_at
    else
        return left.name < right.name
    end
end


local function site_comparator_by_ore_type(left, right)
    if left.ore_type ~= right.ore_type then
        return left.ore_type < right.ore_type
    else
        return site_comparator_default(left, right)
    end
end


local function site_comparator_by_ore_count(left, right)
    if left.amount ~= right.amount then
        return left.amount < right.amount
    else
        return site_comparator_default(left, right)
    end
end


local function site_comparator_by_etd(left, right)
    -- infinite time to depletion is indicated when etd_minutes == -1
    -- we want sites with infinite depletion time at the end of the list
    if left.etd_minutes ~= right.etd_minutes then
        if left.etd_minutes >= 0 and right.etd_minutes >= 0 then
            -- these are both real etd estimates so sort normally
            return left.etd_minutes < right.etd_minutes
        else
            -- left and right are not equal AND one of them is -1
            -- (they are not both -1 because then they'd be equal)
            -- and we want -1 to be at the end of the list
            -- so reverse the sort order in this case
            return left.etd_minutes > right.etd_minutes
        end
    else
        return site_comparator_default(left, right)
    end
end


local function site_comparator_by_alpha(left, right)
    return left.name < right.name
end


local function sites_in_order(sites, comparator)
    -- damn in-place table.sort makes us make a copy first...
    local ordered_sites = {}
    for _, site in pairs(sites) do
        table.insert(ordered_sites, site)
    end

    table.sort(ordered_sites, comparator)

    local i = 0
    local n = #ordered_sites
    return function()
        i = i + 1
        if i <= n then return ordered_sites[i] end
    end
end


local function sites_in_player_order(sites, player)
    local order_by = player.mod_settings["YARM-order-by"].value

    local comparator =
        (order_by == 'ore-type' and site_comparator_by_ore_type)
        or (order_by == 'ore-count' and site_comparator_by_ore_count)
        or (order_by == 'etd' and site_comparator_by_etd)
        or (order_by == 'alphabetical' and site_comparator_by_alpha)
        or site_comparator_default

    return sites_in_order(sites, comparator)
end

-- NB: filter names should be single words with optional underscores (_)
-- They will be used for naming GUI elements
local FILTER_NONE = "none"
local FILTER_WARNINGS = "warnings"
local FILTER_ALL = "all"

resmon.filters[FILTER_NONE] = function() return false end
resmon.filters[FILTER_ALL] = function() return true end
resmon.filters[FILTER_WARNINGS] = function(site, player)
    local remaining = site.etd_minutes
    local threshold_hours = site.is_summary and "timeleft_totals" or "timeleft"
    return remaining ~= -1 and remaining <= player.mod_settings["YARM-warn-" .. threshold_hours].value * 60
end


function resmon.update_ui(player)
    local player_data = global.player_data[player.index]
    local force_data = global.force_data[player.force.name]
    local show_sites_summary = player.mod_settings["YARM-show-sites-summary"].value

    local frame_flow = mod_gui.get_frame_flow(player)
    local root = frame_flow.YARM_root
    if not root then
        root = frame_flow.add { type = "frame",
            name = "YARM_root",
            direction = "horizontal",
            style = "YARM_outer_frame_no_border" }

        local buttons = root.add { type = "flow",
            name = "buttons",
            direction = "vertical",
            style = "YARM_buttons_v" }

        buttons.add { type = "button", name = "YARM_filter_" .. FILTER_NONE, style = "YARM_filter_none",
            tooltip = { "YARM-tooltips.filter-none" } }
        buttons.add { type = "button", name = "YARM_filter_" .. FILTER_WARNINGS, style = "YARM_filter_warnings",
            tooltip = { "YARM-tooltips.filter-warnings" } }
        buttons.add { type = "button", name = "YARM_filter_" .. FILTER_ALL, style = "YARM_filter_all",
            tooltip = { "YARM-tooltips.filter-all" } }
        buttons.add { type = "button", name = "YARM_toggle_bg", style = "YARM_toggle_bg",
            tooltip = { "YARM-tooltips.toggle-bg" } }
        buttons.add { type = "button", name = "YARM_toggle_surfacesplit", style = "YARM_toggle_surfacesplit",
            tooltip = { "YARM-tooltips.toggle-surfacesplit" } }
        buttons.add { type = "button", name = "YARM_toggle_lite", style = "YARM_toggle_lite",
            tooltip = { "YARM-tooltips.toggle-lite" } }

        if not player_data.active_filter then player_data.active_filter = FILTER_WARNINGS end
        resmon.update_ui_filter_buttons(player, player_data.active_filter)
    end

    if root.sites and root.sites.valid then
        root.sites.destroy()
    end

    if not force_data or not force_data.ore_sites then return end

    local is_full = root.buttons.YARM_toggle_lite.style.name ~= "YARM_toggle_lite_on"
    local column_count = is_full and 12 or 5
    local sites_gui = root.add { type = "table", column_count = column_count, name = "sites", style = "YARM_site_table" }
    sites_gui.style.horizontal_spacing = 5
    local column_alignments = sites_gui.style.column_alignments
    if is_full then
        column_alignments[1] = 'left'    -- rename button
        column_alignments[2] = 'left'    -- surface name
        column_alignments[3] = 'left'    -- site name
        column_alignments[4] = 'right'   -- remaining percent
        column_alignments[5] = 'right'   -- site amount
        column_alignments[6] = 'left'    -- ore name
        column_alignments[7] = 'right'   -- ore per minute
        column_alignments[8] = 'left'    -- ETD
        column_alignments[9] = 'right'   -- ETD
        column_alignments[10] = 'left'   -- ETD
        column_alignments[11] = 'center' -- ETD
        column_alignments[12] = 'left'   -- buttons
    else
        column_alignments[1] = 'left'    -- surface name
        column_alignments[2] = 'left'    -- site name
        column_alignments[3] = 'left'    -- ore name
        column_alignments[4] = 'right'   -- ETD
        column_alignments[5] = 'left'    -- buttons
    end

    local site_filter = resmon.filters[player_data.active_filter] or resmon.filters[FILTER_NONE]
    local surface_filters = { false }
    if root.buttons.YARM_toggle_surfacesplit.style.name == "YARM_toggle_surfacesplit_on" then
        surface_filters = resmon.surface_filters()
    end
    local surface_num = 0
    local rendered_last = false

    for _, surface_filter in pairs(surface_filters) do
        local sites = resmon.get_sites_on_surface(force_data, player, surface_filter)
        if next(sites) then
            local will_render_sites
            local will_render_totals
            local summary = show_sites_summary and resmon.generate_summaries(player, sites) or {}
            for summary_site in sites_in_player_order(summary, player) do
                if site_filter(summary_site, player) then will_render_totals = true end
            end
            for _, site in pairs(sites) do
                if site_filter(site, player) then will_render_sites = true end
            end

            surface_num = surface_num + 1
            if surface_num > 1 and rendered_last and (will_render_totals or will_render_sites) then
                for _ = 1, column_count do sites_gui.add { type = "line" } end
                for _ = 1, column_count do sites_gui.add { type = "line" } end
                for _ = 1, column_count do sites_gui.add { type = "line" } end
            end
            rendered_last = rendered_last or will_render_totals or will_render_sites

            local row = 1
            for summary_site in sites_in_player_order(summary, player) do
                if resmon.print_single_site(site_filter, summary_site, player, sites_gui, player_data, row, is_full) then
                    row = row + 1
                end
            end
            if will_render_totals and will_render_sites then
                if is_full then
                    sites_gui.add { type = "label" }.style.maximal_height = 5
                end
                sites_gui.add { type = "label" }.style.maximal_height = 5
                sites_gui.add { type = "label", caption = { "YARM-category-sites" } }
                local start = is_full and 4 or 3
                for _ = start, column_count do sites_gui.add { type = "label" }.style.maximal_height = 5 end
            end
            row = 1
            for _, site in pairs(sites) do
                if resmon.print_single_site(site_filter, site, player, sites_gui, player_data, row, is_full) then
                    row = row + 1
                end
            end
        end
    end
end

function resmon.get_sites_on_surface(force_data, player, surface_filter)
    local filtered_sites = {}
    for site in sites_in_player_order(force_data.ore_sites, player) do
        if resmon.site_is_on_surface(site, surface_filter) then
            table.insert(filtered_sites, site)
        end
    end
    return filtered_sites
end

function resmon.surface_filters()
    local surface_filters = {}
    for k in pairs(game.surfaces) do table.insert(surface_filters, k) end
    return surface_filters
end

function resmon.site_is_on_surface(site, surface_filter)
    return not surface_filter or site.surface.name == surface_filter
end

function resmon.generate_summaries(player, sites)
    local summary = {}
    for _, site in pairs(sites) do
        local entity_prototype = game.entity_prototypes[site.ore_type]
        local is_endless = resmon.is_endless_resource(site.ore_type, entity_prototype) and 1 or nil
        local root = mod_gui.get_frame_flow(player).YARM_root
        local summary_id = site.ore_type ..
            (root.buttons.YARM_toggle_surfacesplit.style.name == "YARM_toggle_surfacesplit_on" and site.surface.name or "")
        if not summary[summary_id] then
            summary[summary_id] = {
                name = "Total " .. summary_id,
                ore_type = site.ore_type,
                ore_name = site.ore_name,
                initial_amount = 0,
                amount = 0,
                ore_per_minute = 0,
                etd_minutes = 0,
                is_summary = 1,
                entity_count = 0,
                remaining_permille = (is_endless and 0 or 1000),
                site_count = 0,
                etd_minutes_delta = 0,
                ore_per_minute_delta = 0,
                surface = site.surface,
            }
        end

        local summary_site = summary[summary_id]
        summary_site.site_count = summary_site.site_count + 1
        summary_site.initial_amount = summary_site.initial_amount + site.initial_amount
        summary_site.amount = summary_site.amount + site.amount
        summary_site.ore_per_minute = summary_site.ore_per_minute + site.ore_per_minute
        summary_site.entity_count = summary_site.entity_count + site.entity_count
        summary_site.remaining_permille = resmon.calc_remaining_permille(summary_site)
        local minimum = is_endless and (summary_site.entity_count * entity_prototype.minimum_resource_amount) or 0
        local amount_left = summary_site.amount - minimum
        summary_site.etd_minutes =
            (summary_site.ore_per_minute ~= 0 and amount_left / (-summary_site.ore_per_minute))
            or (amount_left == 0 and 0)
            or -1
        summary_site.etd_minutes_delta = summary_site.etd_minutes_delta + (site.etd_minutes_delta or 0)
        summary_site.ore_per_minute_delta = summary_site.ore_per_minute_delta + (site.ore_per_minute_delta or 0)
    end
    return summary
end

function resmon.on_click.set_filter(event)
    local new_filter = string.sub(event.element.name, 1 + string.len("YARM_filter_"))
    local player = game.players[event.player_index]
    local player_data = global.player_data[event.player_index]

    player_data.active_filter = new_filter

    resmon.update_ui_filter_buttons(player, new_filter)

    resmon.update_ui(player)
end

function resmon.update_ui_filter_buttons(player, active_filter)
    -- rarely, it might be possible to arrive here before the YARM GUI gets created
    local root = mod_gui.get_frame_flow(player).YARM_root
    -- in that case, leave it for a later update_ui call.
    if not root or not root.valid then return end

    local buttons_container = root.buttons
    for filter_name, _ in pairs(resmon.filters) do
        local is_active_filter = filter_name == active_filter

        local button = buttons_container["YARM_filter_" .. filter_name]
        if button and button.valid then
            local style_name = button.style.name
            local is_active_style = style_name:ends_with("_on")

            if is_active_style and not is_active_filter then
                button.style = string.sub(style_name, 1, string.len(style_name) - 3)
            elseif is_active_filter and not is_active_style then
                button.style = style_name .. "_on"
            end
        end
    end
end

function resmon.print_single_site(site_filter, site, player, sites_gui, player_data, row, is_full)
    if not site_filter(site, player) then return end

    -- TODO: This shouldn't be part of printing the site! It cancels the deletion
    -- process after 2 seconds pass.
    if site.deleting_since and site.deleting_since + 120 < game.tick then
        site.deleting_since = nil
    end

    local color = resmon.site_color(site, player)
    local el = nil
    local root = mod_gui.get_frame_flow(player).YARM_root

    if not site.is_summary then
        if is_full then
            if player_data.renaming_site == site.name then
                sites_gui.add { type = "button",
                    name = "YARM_rename_site_" .. site.name,
                    tooltip = { "YARM-tooltips.rename-site-cancel" },
                    style = "YARM_rename_site_cancel" }
            else
                sites_gui.add { type = "button",
                    name = "YARM_rename_site_" .. site.name,
                    tooltip = { "YARM-tooltips.rename-site-named", site.name },
                    style = "YARM_rename_site" }
            end
        end

        local surf_name = root.buttons.YARM_toggle_surfacesplit.style.name == "YARM_toggle_surfacesplit_on"
            and site.surface.name or ""
        el = sites_gui.add { type = "label", name = "YARM_label_surface_" .. site.name, caption = surf_name }
        el.style.font_color = color

        el = sites_gui.add { type = "label", name = "YARM_label_site_" .. site.name, caption = site.name }
        el.style.font_color = color
    else
        if is_full then
            sites_gui.add { type = "label" }
        end
        local surface = (root.buttons.YARM_toggle_surfacesplit.style.name == "YARM_toggle_surfacesplit_on" and row == 1)
            and site.surface.name or ""
        sites_gui.add { type = "label", caption = surface }
        local totals = row == 1 and { "YARM-category-totals" } or ""
        sites_gui.add { type = "label", caption = totals }
    end

    if is_full then
        el = sites_gui.add { type = "label", name = "YARM_label_percent_" .. site.name,
            caption = string.format("%.1f%%", site.remaining_permille / 10) }
        el.style.font_color = color

        local display_amount = resmon.generate_display_site_amount(site, player, nil)
        el = sites_gui.add { type = "label", name = "YARM_label_amount_" .. site.name,
            caption = display_amount }
        el.style.font_color = color
    end

    local entity_prototype = game.entity_prototypes[site.ore_type]
    el = sites_gui.add { type = "label", name = "YARM_label_ore_name_" .. site.name,
        caption = is_full and { "", resmon.get_rich_text_for_products(entity_prototype), " ", site.ore_name }
            or resmon.get_rich_text_for_products(entity_prototype) }
    el.style.font_color = color

    if is_full then
        el = sites_gui.add { type = "label", name = "YARM_label_ore_per_minute_" .. site.name,
            caption = resmon.render_speed(site, player) }
        el.style.font_color = color

        resmon.render_arrow_for_percent_delta(sites_gui, -1 * site.ore_per_minute_delta, site.ore_per_minute)
    end

    el = sites_gui.add { type = "label", name = "YARM_label_etd_" .. site.name,
        caption = resmon.time_to_deplete(site) }
    el.style.font_color = color

    if is_full then
        resmon.render_arrow_for_percent_delta(sites_gui, site.etd_minutes_delta, site.etd_minutes)

        if not site.is_summary then
            local etd_icon = site.etd_is_lifetime == 1 and "[img=quantity-time]" or "[img=utility/played_green]"
            el = sites_gui.add { type = "label", name = "YARM_label_etd_header_" .. site.name,
                caption = { "YARM-time-to-deplete", etd_icon } }
            el.style.font_color = color
        else
            sites_gui.add { type = "label", caption = "" }
        end
    end

    local site_buttons = sites_gui.add { type = "flow", name = "YARM_site_buttons_" .. site.name,
        direction = "horizontal", style = "YARM_buttons_h" }

    if not site.is_summary then
        site_buttons.add { type = "button",
            name = "YARM_goto_site_" .. site.name,
            tooltip = { "YARM-tooltips.goto-site" },
            style = "YARM_goto_site" }

        if is_full then
            if site.deleting_since then
                site_buttons.add { type = "button",
                    name = "YARM_delete_site_" .. site.name,
                    tooltip = { "YARM-tooltips.delete-site-confirm" },
                    style = "YARM_delete_site_confirm" }
            else
                site_buttons.add { type = "button",
                    name = "YARM_delete_site_" .. site.name,
                    tooltip = { "YARM-tooltips.delete-site" },
                    style = "YARM_delete_site" }
            end

            if site.is_site_expanding then
                site_buttons.add { type = "button",
                    name = "YARM_expand_site_" .. site.name,
                    tooltip = { "YARM-tooltips.expand-site-cancel" },
                    style = "YARM_expand_site_cancel" }
            else
                site_buttons.add { type = "button",
                    name = "YARM_expand_site_" .. site.name,
                    tooltip = { "YARM-tooltips.expand-site" },
                    style = "YARM_expand_site" }
            end
        end
    end

    return true
end

function resmon.render_arrow_for_percent_delta(sites_gui, delta, amount)
    local percent_delta = (100 * (delta or 0) / (amount or 0)) / 5
    local hue = percent_delta >= 0 and (1 / 3) or 0
    local saturation = math.min(math.abs(percent_delta), 1)
    local value = math.min(0.5 + math.abs(percent_delta / 2), 1)
    sites_gui.add({ type = "label", caption = (amount == 0 and "") or (delta or 0) >= 0 and "⬆" or "⬇" }).style.font_color =
        resmon.hsv2rgb(hue, saturation, value)
end

function resmon.time_to_deplete(site)
    local ups_adjust = settings.global["YARM-nominal-ups"].value / 60
    local minutes = (site.etd_minutes and (site.etd_minutes / ups_adjust)) or -1

    if minutes == -1 or minutes == math.huge then return { "YARM-etd-never" } end

    local hours = math.floor(minutes / 60)
    local days = math.floor(hours / 24)
    hours = hours % 24
    minutes = minutes % 60
    local time_frag = { "YARM-etd-hour-fragment",
        { "", string.format("%02d", hours), ":", string.format("%02d", math.floor(minutes)) } }

    if days > 0 then
        return { "", { "YARM-etd-day-fragment", days }, " ", time_frag }
    elseif minutes > 0 then
        return time_frag
    elseif site.amount_left == 0 then
        return { "YARM-etd-now" }
    else
        return { "YARM-etd-under-1m" }
    end
end

function resmon.render_speed(site, player)
    local ups_adjust = settings.global["YARM-nominal-ups"].value / 60
    local speed = ups_adjust * site.ore_per_minute

    local entity_prototype = game.entity_prototypes[site.ore_type]
    if resmon.is_endless_resource(site.ore_type, entity_prototype) then
        local normal_site_amount = entity_prototype.normal_resource_amount * site.entity_count
        local speed_display = (normal_site_amount == 0 and 0) or (100 * speed) / normal_site_amount
        return resmon.speed_to_human("%.3f%%", speed_display, -0.001)
    end

    local speed_display = resmon.speed_to_human("%.1f", speed, -0.1)

    if not settings.global["YARM-adjust-for-productivity"].value then
        return speed_display
    end

    local speed_prod = speed * (1 + (player or site).force.mining_drill_productivity_bonus)
    local speed_prod_display = resmon.speed_to_human("%.1f", speed_prod, -0.1)

    if not settings.global["YARM-productivity-show-raw-and-adjusted"].value then
        return speed_prod_display
    elseif settings.global["YARM-productivity-parentheses-part-is"].value == "adjusted" then
        return { "", speed_display, " (", speed_prod_display, ")" }
    else
        return { "", speed_prod_display, " (", speed_display, ")" }
    end
end

function resmon.speed_to_human(format, speed, limit)
    local speed_display =
        speed < limit and { "YARM-ore-per-minute", format_number(string.format(format, speed)) } or
        speed < 0 and { "YARM-ore-per-minute", { "", "<", string.format(format, -0.1) } } or ""
    return speed_display
end

function resmon.site_color(site, player)
    local threshold_type = site.is_summary and "timeleft_totals" or "timeleft"
    local threshold = player.mod_settings["YARM-warn-" .. threshold_type].value * 60
    local minutes = site.etd_minutes
    if minutes == -1 then minutes = threshold end
    local factor = (threshold == 0 and 1) or (minutes / threshold)
    if factor > 1 then factor = 1 end
    local hue = factor / 3
    return resmon.hsv2rgb(hue, 1, 1)
end

function resmon.hsv2rgb(h, s, v)
    local r, g, b
    local i = math.floor(h * 6);
    local f = h * 6 - i;
    local p = v * (1 - s);
    local q = v * (1 - f * s);
    local t = v * (1 - (1 - f) * s);
    i = i % 6
    if i == 0 then
        r, g, b = v, t, p
    elseif i == 1 then
        r, g, b = q, v, p
    elseif i == 2 then
        r, g, b = p, v, t
    elseif i == 3 then
        r, g, b = p, q, v
    elseif i == 4 then
        r, g, b = t, p, v
    elseif i == 5 then
        r, g, b = v, p, q
    end
    return { r = r, g = g, b = b }
end

function resmon.on_click.YARM_rename_confirm(event)
    local player = game.players[event.player_index]
    local player_data = global.player_data[event.player_index]
    local force_data = global.force_data[player.force.name]

    local old_name = player_data.renaming_site
    local new_name = player.gui.center.YARM_site_rename.new_name.text

    if string.len(new_name) > MAX_SITE_NAME_LENGTH then
        player.print { 'YARM-err-site-name-too-long', MAX_SITE_NAME_LENGTH }
        return
    end

    local site = force_data.ore_sites[old_name]
    force_data.ore_sites[old_name] = nil
    force_data.ore_sites[new_name] = site
    site.name = new_name

    resmon.update_chart_tag(site)

    player_data.renaming_site = nil
    player.gui.center.YARM_site_rename.destroy()

    resmon.update_force_members_ui(player)
end

function resmon.on_click.YARM_rename_cancel(event)
    local player = game.players[event.player_index]
    local player_data = global.player_data[event.player_index]

    player_data.renaming_site = nil
    player.gui.center.YARM_site_rename.destroy()

    resmon.update_force_members_ui(player)
end

function resmon.on_click.rename_site(event)
    local site_name = string.sub(event.element.name, 1 + string.len("YARM_rename_site_"))

    local player = game.players[event.player_index]
    local player_data = global.player_data[event.player_index]

    if player.gui.center.YARM_site_rename then
        resmon.on_click.YARM_rename_cancel(event)
        return
    end

    player_data.renaming_site = site_name
    local root = player.gui.center.add { type = "frame",
        name = "YARM_site_rename",
        caption = { "YARM-site-rename-title", site_name },
        direction = "horizontal" }

    root.add { type = "textfield", name = "new_name" }.text = site_name
    root.add { type = "button", name = "YARM_rename_confirm", caption = { "YARM-site-rename-confirm" } }
    root.add { type = "button", name = "YARM_rename_cancel", caption = { "YARM-site-rename-cancel" } }

    player.opened = root

    resmon.update_force_members_ui(player)
end

function resmon.on_gui_closed(event)
    if event.gui_type ~= defines.gui_type.custom then return end
    if not event.element or not event.element.valid then return end
    if event.element.name ~= "YARM_site_rename" then return end

    resmon.on_click.YARM_rename_cancel(event)
end

function resmon.on_click.remove_site(event)
    local site_name = string.sub(event.element.name, 1 + string.len("YARM_delete_site_"))

    local player = game.players[event.player_index]
    local force_data = global.force_data[player.force.name]
    local site = force_data.ore_sites[site_name]

    if site.deleting_since then
        force_data.ore_sites[site_name] = nil

        if site.chart_tag and site.chart_tag.valid then
            site.chart_tag.destroy()
        end
    else
        site.deleting_since = event.tick
    end

    resmon.update_force_members_ui(player)
end

function resmon.on_click.goto_site(event)
    local site_name = string.sub(event.element.name, 1 + string.len("YARM_goto_site_"))

    local player = game.players[event.player_index]
    local force_data = global.force_data[player.force.name]
    local site = force_data.ore_sites[site_name]

    if game.active_mods["space-exploration"] ~= nil then
        local zone = remote.call("space-exploration", "get_zone_from_surface_index",
            { surface_index = site.surface.index })
        if not zone then
            -- the zone is not available for some reason.
            player.print { "YARM-spaceexploration-zone-unavailable" }
            log("YARM: Unavailable to view SE zone at " .. serpent.line(site.center) .. " on surface " .. site.surface)
            return
        end -- TODO: need to show some error logs for this
        player.close_map()
        remote.call("space-exploration", "remote_view_start",
            {
                player = player,
                zone_name = zone.name,
                position = site.center,
                location_name = site.name,
                freeze_history = true
            })
    else
        player.open_map(site.center)
    end

    resmon.update_force_members_ui(player)
end

-- one button handler for both the expand_site and expand_site_cancel buttons
function resmon.on_click.expand_site(event)
    local site_name = string.sub(event.element.name, 1 + string.len("YARM_expand_site_"))

    local player = game.players[event.player_index]
    local player_data = global.player_data[event.player_index]
    local force_data = global.force_data[player.force.name]
    local site = force_data.ore_sites[site_name]
    local are_we_cancelling_expand = site.is_site_expanding

    --[[ we want to submit the site if we're cancelling the expansion (mostly because submitting the
         site cleans up the expansion-related variables on the site) or if we were adding a new site
         and decide to expand an existing one
    --]]
    if are_we_cancelling_expand or player_data.current_site then
        resmon.submit_site(event.player_index)
    end

    --[[ this is to handle cancelling an expansion (by clicking the red button) - submitting the site is
         all we need to do in this case ]]
    if are_we_cancelling_expand then
        resmon.update_force_members_ui(player)
        return
    end

    resmon.pull_YARM_item_to_cursor_if_possible(event.player_index)
    if player.cursor_stack.valid_for_read and player.cursor_stack.name == "yarm-selector-tool" then
        site.is_site_expanding = true
        player_data.current_site = site

        resmon.update_force_members_ui(player)
        resmon.start_recreate_overlay_existing_site(event.player_index)
    end
end

function resmon.on_click.toggle_bg(event)
    local player = game.players[event.player_index]
    local root = mod_gui.get_frame_flow(player).YARM_root
    if not root then return end
    root.style = (root.style.name == "YARM_outer_frame_no_border_bg")
        and "YARM_outer_frame_no_border" or "YARM_outer_frame_no_border_bg"
    local button = root.buttons.YARM_toggle_bg
    button.style = button.style.name == "YARM_toggle_bg" and "YARM_toggle_bg_on" or "YARM_toggle_bg"
    resmon.update_ui(player)
end

function resmon.on_click.toggle_surfacesplit(event)
    local player = game.players[event.player_index]
    local root = mod_gui.get_frame_flow(player).YARM_root
    if not root then return end
    local button = root.buttons.YARM_toggle_surfacesplit
    button.style =
        button.style.name == "YARM_toggle_surfacesplit" and "YARM_toggle_surfacesplit_on" or "YARM_toggle_surfacesplit"
    resmon.update_ui(player)
end

function resmon.on_click.toggle_lite(event)
    local player = game.players[event.player_index]
    local root = mod_gui.get_frame_flow(player).YARM_root
    if not root then return end
    local button = root.buttons.YARM_toggle_lite
    button.style =
        button.style.name == "YARM_toggle_lite" and "YARM_toggle_lite_on" or "YARM_toggle_lite"
    resmon.update_ui(player)
end

function resmon.pull_YARM_item_to_cursor_if_possible(player_index)
    local player = game.players[player_index]
    if player.cursor_stack.valid_for_read then -- already have something?
        if player.cursor_stack.name == "yarm-selector-tool" then return end

        player.clear_cursor() -- and it's not a selector tool, so Q it away
    end

    player.cursor_stack.set_stack { name = "yarm-selector-tool" }
end

function resmon.on_get_selection_tool(event)
    resmon.pull_YARM_item_to_cursor_if_possible(event.player_index)
end

function resmon.start_recreate_overlay_existing_site(player_index)
    local site = global.player_data[player_index].current_site
    site.is_overlay_being_created = true

    -- forcible cleanup in case we got interrupted during a previous background overlay attempt
    site.entities_to_be_overlaid = {}
    site.entities_to_be_overlaid_count = 0
    site.next_to_overlay = {}
    site.next_to_overlay_count = 0

    for index in pairs(site.tracker_indices) do
        local tracking_data = resmon.entity_cache[index]
        if tracking_data then
            local ent = tracking_data.entity
            if ent and ent.valid then
                local key = position_to_string(ent.position)
                site.entities_to_be_overlaid[key] = ent.position
                site.entities_to_be_overlaid_count = site.entities_to_be_overlaid_count + 1
            end
        end
    end
end

function resmon.process_overlay_for_existing_site(player_index)
    local player_data = global.player_data[player_index]
    local site = player_data.current_site

    if site.next_to_overlay_count == 0 then
        if site.entities_to_be_overlaid_count == 0 then
            resmon.end_overlay_creation_for_existing_site(player_index)
            return
        else
            local ent_key, ent_pos = next(site.entities_to_be_overlaid)
            site.next_to_overlay[ent_key] = ent_pos
            site.next_to_overlay_count = site.next_to_overlay_count + 1
        end
    end

    local to_scan = math.min(30, site.next_to_overlay_count)
    for i = 1, to_scan do
        local ent_key, ent_pos = next(site.next_to_overlay)

        local entity = site.surface.find_entity(site.ore_type, ent_pos)
        local entity_position = entity.position
        local surface = entity.surface
        local key = position_to_string(entity_position)

        -- put marker down
        resmon.put_marker_at(surface, entity_position, player_data)
        -- remove it from our to-do lists
        site.entities_to_be_overlaid[key] = nil
        site.entities_to_be_overlaid_count = site.entities_to_be_overlaid_count - 1
        site.next_to_overlay[key] = nil
        site.next_to_overlay_count = site.next_to_overlay_count - 1

        -- Look in every direction around this entity...
        for _, dir in pairs(defines.direction) do
            -- ...and if there's a resource that's not already overlaid, add it
            local found = find_resource_at(surface, shift_position(entity_position, dir))
            if found and found.name == site.ore_type then
                local offsetkey = position_to_string(found.position)
                if site.entities_to_be_overlaid[offsetkey] ~= nil and site.next_to_overlay[offsetkey] == nil then
                    site.next_to_overlay[offsetkey] = found.position
                    site.next_to_overlay_count = site.next_to_overlay_count + 1
                end
            end
        end
    end
end

function resmon.end_overlay_creation_for_existing_site(player_index)
    local site = global.player_data[player_index].current_site
    site.is_overlay_being_created = false
    site.finalizing = true
    site.finalizing_since = game.tick
end

function resmon.update_force_members_ui(player)
    for _, p in pairs(player.force.players) do
        resmon.update_ui(p)
    end
end

function resmon.on_gui_click(event)
    if resmon.on_click[event.element.name] then
        resmon.on_click[event.element.name](event)
    elseif string.starts_with(event.element.name, "YARM_filter_") then
        resmon.on_click.set_filter(event)
    elseif string.starts_with(event.element.name, "YARM_delete_site_") then
        resmon.on_click.remove_site(event)
    elseif string.starts_with(event.element.name, "YARM_rename_site_") then
        resmon.on_click.rename_site(event)
    elseif string.starts_with(event.element.name, "YARM_goto_site_") then
        resmon.on_click.goto_site(event)
    elseif string.starts_with(event.element.name, "YARM_expand_site_") then
        resmon.on_click.expand_site(event)
    elseif string.starts_with(event.element.name, "YARM_toggle_bg") then
        resmon.on_click.toggle_bg(event)
    elseif string.starts_with(event.element.name, "YARM_toggle_surfacesplit") then
        resmon.on_click.toggle_surfacesplit(event)
    elseif string.starts_with(event.element.name, "YARM_toggle_lite") then
        resmon.on_click.toggle_lite(event)
    end
end

function resmon.update_players(event)
    -- At tick 0 on an MP server initial join, on_init may not have run
    if not global.player_data then return end

    for index, player in pairs(game.players) do
        local player_data = global.player_data[index]

        if not player_data then
            resmon.init_player(index)
        elseif not player.connected and player_data.current_site then
            resmon.clear_current_site(index)
        end

        if player_data.current_site then
            local site = player_data.current_site

            if #site.next_to_scan > 0 then
                resmon.scan_current_site(index)
            elseif not site.finalizing then
                resmon.finalize_site(index)
            elseif site.finalizing_since + 120 == event.tick then
                resmon.submit_site(index)
            end

            if site.is_overlay_being_created then
                resmon.process_overlay_for_existing_site(index)
            end
        else
            local todo = player_data.todo or {}
            if #todo > 0 then
                for _, entity in pairs(table.remove(todo)) do
                    resmon.add_resource(index, entity)
                end
            end
        end

        if event.tick % player_data.gui_update_ticks == 15 + index then
            resmon.update_ui(player)
        end
    end
end

function resmon.update_forces(event)
    -- At tick 0 on an MP server initial join, on_init may not have run
    if not global.force_data then return end

    local update_cycle = event.tick % settings.global["YARM-ticks-between-checks"].value
    for _, force in pairs(game.forces) do
        local force_data = global.force_data[force.name]

        if not force_data then
            resmon.init_force(force)
        elseif force_data and force_data.ore_sites then
            for _, site in pairs(force_data.ore_sites) do
                resmon.count_deposits(site, update_cycle)
            end
        end
    end
end

local function profiler_output(message, stopwatch)
    local output = { "", message, " - ", stopwatch }

    log(output)
    for _, player in pairs(game.players) do
        player.print(output)
    end
end


local function on_tick_internal(event)
    ore_tracker.on_tick(event)
    resmon.entity_cache = ore_tracker.get_entity_cache()

    resmon.update_players(event)
    resmon.update_forces(event)
end


local function on_tick_internal_with_profiling(event)
    local big_stopwatch = game.create_profiler()
    local stopwatch = game.create_profiler()
    ore_tracker.on_tick(event)
    stopwatch.stop()
    profiler_output("ore_tracker", stopwatch)

    resmon.entity_cache = ore_tracker.get_entity_cache()

    stopwatch.reset()
    resmon.update_players(event)
    stopwatch.stop()
    profiler_output("update_players", stopwatch)

    stopwatch.reset()
    resmon.update_forces(event)
    stopwatch.stop()
    profiler_output("update_forces", stopwatch)

    big_stopwatch.stop()
    profiler_output("total on_tick", big_stopwatch)
end


function resmon.on_tick(event)
    local wants_profiling = settings.global["YARM-debug-profiling"].value or false
    if wants_profiling then
        on_tick_internal_with_profiling(event)
    else
        on_tick_internal(event)
    end
end

function resmon.on_load()
    ore_tracker.on_load()
end
