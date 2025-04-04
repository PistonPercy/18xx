const fs = require('node:fs');
const process = require('node:process');

requestAnimationFrame = function(f) {
  setImmediate(f)
}
snabbdom = {
    init: function() {}
}

Big = require('./public/assets/server.js').Big

game_data_str = fs.readFileSync(process.argv[2], 'utf8')
game_data = JSON.parse(game_data_str)
if (game_data["error"]) return;

title = game_data["title"]
get_games_to_load(title)


let target_action = process.argv[3];
game = Opal.Engine.Game.$load(game_data_str, new Map([["at_action", target_action - 1]]))

let filtered_actions = game.filtered_actions
if (!filtered_actions.find((a) => { if (a instanceof Map) { return a.get("id") == target_action}})) {
    process.stdout.write("output:"+JSON.stringify({revenue: "UNDO"})+"\n")
    return
}

router = Opal.Engine.AutoRouter.$new(game)
let start  = process.hrtime()
let routes = null;
let desired_routes = get_desired_data(game_data);
let max_route_walk = new Map(desired_routes.entries().map(([k,v]) => [k, []]))
let max_route_valid_route = new Map(desired_routes.entries().map(([k,v]) => [k, []]))
router.$compute_new(game.$current_entity(), new Map([
    ['routes', []],
    ["path_timeout", 100],
    ["route_timeout", 0],
    ["route_limit", 1],
    ["callback", (routes_) => routes = routes_],
    ["update", () => {}],
    ["path_debugger", path_debugger],
]))
require('node:timers').setInterval(() => {
   if (!routes) return;
   routes.forEach((route) => route["$clear_cache!"](new Map([["only_routes", true]])))
   revenue = game.$routes_revenue(routes)
   time = process.hrtime(start)
   routes.forEach((route) => console.log(route.$revenue_str()));

   process.stdout.write("output:"+JSON.stringify({
     revenue,
     real_revenue_call_count: router.real_revenue_call_count,
     hexside_bits: router.next_hexside_bit,
     max_memory: process.resourceUsage().maxRSS,
     time_seconds: time[0],
     ...router.analytics,
   })+"\n")
  console.log(desired_routes, max_route_walk, max_route_valid_route)
   if ([...desired_routes.keys()].every((k) => array_equal(max_route_walk.get(k), desired_routes.get(k)) || array_reverse_equal(max_route_walk.get(k), desired_routes.get(k))) && desired_routes.size == max_route_walk.size) {
     console.log("walk:SUCCESS");
   } else {
     console.log("walk:FAIL");
   }
   if ([...desired_routes.keys()].every((k) => array_equal(max_route_valid_route.get(k), desired_routes.get(k)) || array_reverse_equal(max_route_valid_route.get(k), desired_routes.get(k))) && desired_routes.size == max_route_valid_route.size) {
     console.log("valid_route:SUCCESS");
   } else {
     console.log("valid_route:FAIL");
   }
   process.exit(0);
})

function array_reverse_equal(a, b) {
  return a.length == b.length && a.every((v, i) => v == b[b.length-i-1]);
}

function array_equal(a, b) {
  return a.length == b.length && a.every((v, i) => v == b[i]);
}

function get_desired_data(game) {
  let action = game["actions"].filter((a) => a["id"] == target_action)[0];
  console.assert(action["type"] == "run_routes", "Action must be run_routes");
  return new Map(action["routes"].map((r) => [r["train"], r["hexes"]]));
}

function get_games_to_load(title) {
  if (!title) return []
  game_meta = Opal.Engine.$meta_by_title(title)
  Opal.top.$require_tree("engine/game/"+game_meta.$fs_name())
  Opal.top.$require("engine/game/"+game_meta.$fs_name())
  get_games_to_load(game_meta.DEPENDS_ON)
}


function array_starts_with(a, b) {
  if (!a || !b) return false;
  return a.length >= b.length && b.every((v, i) => v == a[i]);
}

function reverse_array_starts_with(a, b) {
  if (!a || !b) return false;
  return a.length >= b.length && b.every((v, i) => v == a[a.length-i-1]);
}

function path_debugger(state, route) {
  let name = route.$train().$id()
  let route_hexes = route.$hexes().$to_a().map((h) => h.$id().$to_s());
  let desired_hexes = desired_routes.get(name);

  // check if desired_hexes starts with route hexes
  if (array_starts_with(desired_hexes, route_hexes) || reverse_array_starts_with(desired_hexes, route_hexes)) {
    if (state == "walk") {
      if (max_route_walk.get(name).length < route_hexes.length) {
        max_route_walk.set(name, route_hexes)
      }
    } else if (state == "valid_route") {
      if (max_route_valid_route.get(name).length < route_hexes.length) {
        max_route_valid_route.set(name, route_hexes)
      }
    } else {
      console.assert(false, "Unknown state");
    }
    return true;
  }
  return false;
}
