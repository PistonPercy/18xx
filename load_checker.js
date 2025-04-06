const fs = require('node:fs');
const process = require('node:process');

snabbdom = {
    init: function() {}
}

Big = require('./public/assets/server.js').Big

game_data_str = fs.readFileSync(process.argv[2], 'utf8')
game_data = JSON.parse(game_data_str)
if (game_data["error"]) return;


title = game_data["title"]
get_games_to_load(title)

Opal.Engine.Logger.$set_level(null, true)

if (process.env.VERBOSE) {
      game = Opal.Engine.Game.$load(game_data_str)
} else {
   try{
      game = Opal.Engine.Game.$load(game_data_str)
   } catch ($e) {
     console.log("failed to load:", process.argv[2])
   }
}

// TODO: create a paths checker that makes sure all in gamedata paths are found by the autorouter

function get_games_to_load(title) {
  if (!title) return []
  game_meta = Opal.Engine.$meta_by_title(title)
console.log("loading", game_meta.$fs_name())
  Opal.top.$require_tree("engine/game/"+game_meta.$fs_name())
  Opal.top.$require("engine/game/"+game_meta.$fs_name())
  get_games_to_load(game_meta.DEPENDS_ON)
}
