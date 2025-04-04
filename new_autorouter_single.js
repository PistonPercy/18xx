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
router.$compute_new(game.$current_entity(), new Map([
    ['routes', []],
    ["path_timeout", 100],
    ["route_timeout", 100],
    ["route_limit", 100000],
    ["callback", (routes_) => routes = routes_],
    ["update", () => {}],
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
   process.exit(0);
})

function get_games_to_load(title) {
  if (!title) return []
  game_meta = Opal.Engine.$meta_by_title(title)
  Opal.top.$require_tree("engine/game/"+game_meta.$fs_name())
  Opal.top.$require("engine/game/"+game_meta.$fs_name())
  get_games_to_load(game_meta.DEPENDS_ON)
}
