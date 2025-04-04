const fs = require('node:fs');

Big = function () {}
snabbdom = {
    init: function() {}
}

Big = require('./public/assets/deps.js').Big
require('./public/assets/main.js')

game_data_str = fs.readFileSync('.game-corpus/137909.json', 'utf8')
game_data = JSON.parse(game_data_str)

title = game_data["title"]
game_meta = Opal.Engine.$meta_by_title(title)
title = game_meta.$fs_name()

console.log(title)
require('./public/assets/'+title+'.js')
Opal.top.$require_tree("engine/game/"+title)
Opal.top.$require("engine/game/"+title)
// TODO ::DEPENDS_ON

Opal.Engine.Logger.$set_level(null, true)

for (let action of game_data["actions"]) {
  if (action["type"] != "run_routes") continue;
  console.log("exploring id:", action["id"])
  game = Opal.Engine.Game.$load(game_data_str, new Map([["at_action", action["id"] - 1]]))
  router = Opal.Engine.AutoRouter.$new(game, null)
  let routes = router.$compute(game.$current_entity(), new Map([['routes', []]]))

  try {
     revenue = game.$routes_revenue(routes)
  } catch ($e) {
     revenue = "DNF";
  }
  console.log({revenue, hexside_bits: router.next_hexside_bit})
}

// TODO: create a paths checker that makes sure all in gamedata paths are found by the autorouter

