const fs = require('node:fs');
const process = require('node:process');

snabbdom = {
    init: function() {}
}

Big = require('./public/assets/server.js').Big
Opal.config.enable_stack_trace = false
game_data_str = fs.readFileSync(process.argv[2], 'utf8')
game_data = JSON.parse(game_data_str)
if (game_data["error"]) return;

title = game_data["title"]
get_games_to_load(title)


//console.log(game_data["actions"])

let target_action = process.argv[3];
game = Opal.Engine.Game.$load(game_data_str, new Map([["at_action", target_action - 1]]))
//process.stdout.write(JSON.stringify(Opal.Engine.Game));
let filtered_actions = game.filtered_actions
console.log()
if (!filtered_actions.find((a) => { if (a instanceof Map) { return a.get("id") == target_action}})) {
    process.stdout.write("output:"+JSON.stringify({revenue: "UNDO"})+"\n")
    return
}

router = Opal.Engine.AutoRouter.$new(game)
let start  = process.hrtime()
try {
let routes = router.$compute(game.$current_entity(), new Map([
    ['routes', []],
    ["path_timeout", 100],
    ["route_timeout", 100],
    ["route_limit", 100000],
]))
   routes.forEach((route) => route["$clear_cache!"](new Map([["only_routes", true]])))
   revenue = game.$routes_revenue(routes)
   console.log(routes.map((r)=>r.$revenue_str()))
} catch (e) {
   console.log(e)
   revenue = "DNF";
}
let time = process.hrtime(start)

process.stdout.write("output:"+JSON.stringify({revenue, hexside_bits: router.next_hexside_bit, time_seconds: time[0]})+"\n")

function get_games_to_load(title) {
  if (!title) return []
  game_meta = Opal.Engine.$meta_by_title(title)
  Opal.top.$require_tree("engine/game/"+game_meta.$fs_name())
  Opal.top.$require("engine/game/"+game_meta.$fs_name())
  get_games_to_load(game_meta.DEPENDS_ON)
}
