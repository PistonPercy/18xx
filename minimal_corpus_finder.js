const fs = require('node:fs');
const process = require('node:process');

snabbdom = {
    init: function() {}
}

Big = require('./public/assets/server.js').Big

let games_to_meta = {}
Opal.Engine.GAME_META_BY_TITLE.forEach((meta, title) => games_to_meta[title] = {
  stage: meta.$const_get('DEV_STAGE'),
  count: 0,
})

let chosen_games = []
for (let game_file of process.argv.slice(2)) {
    let game_data_str = fs.readFileSync(game_file, 'utf8')
    let game_data;
    try {
      game_data = JSON.parse(game_data_str)
    } catch (e) {
      continue;
    }
    if (game_data["error"]) continue;
    if (games_to_meta[game_data["title"]].stage != "production") { continue};
    if (games_to_meta[game_data["title"]].count > 3) { continue; }
    if (game_data["actions"].reduce((total,x) => (x["type"] == "run_routes" ? total+1 : total), 0) < 15) { continue; }
    chosen_games.push(game_file);
    games_to_meta[game_data["title"]].count += 1;
}

for (const [title, d] of Object.entries(games_to_meta)) {
  if (d.stage == "production" && d.count < 3) {
    console.log("Missing some for", title, d.count)
  }
}

process.stdout.write(chosen_games.join(" "))
