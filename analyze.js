const fs = require('node:fs');

snabbdom = {
    init: function() {}
}

Big = require('./public/assets/server.js').Big

games = {}
game_id_to_title = {}

let output = JSON.parse(fs.readFileSync('output.json', 'utf8'))

for (let game_file of process.argv.slice(2)) {
    let game_data_str = fs.readFileSync(game_file, 'utf8')
    let game_data;
    try {
      game_data = JSON.parse(game_data_str)
    } catch (e) {
      console.log("failed to parse", game_file);
      continue;
    }
    if (game_data["error"]) continue;

    let title = game_data["title"]
    if (!games[title]) {
        games[title] = {
          auto_win: 0,
          auto_lose: 0,
          equal: 0,
        }
    }

    let undone_ids = get_undone_ids(game_data)
    for (let action of game_data["actions"]) {
        if (action["type"] != "run_routes") continue;
        if (undone_ids.has(action["id"])) continue;
        if (!output[game_data["id"]+':'+action["id"]]) continue;
        if (output[game_data["id"]+':'+action["id"]].revenue == "UNDO") continue;
        if (output[game_data["id"]+':'+action["id"]].time_seconds > 60) continue;
        let hand_revenue = action["routes"].map((r)=>r.revenue).reduce((b, a) => b + a, 0)
        let auto_revenue = output[game_data["id"]+':'+action["id"]].revenue
            if (title == "1846" && output[game_data["id"]+':'+action["id"]].time_seconds > 5) console.log(game_data["id"]+':'+action["id"])
        if (auto_revenue > hand_revenue) {
            games[title].auto_win += 1
        } else if (auto_revenue == hand_revenue) {
            games[title].equal += 1
        } else {
            games[title].auto_lose += 1
        }
    }
}

// todo off by one still feels right, test this
function get_undone_ids(game_data) {
    let undo_blocks = []
    let last_valid_id = -1;
    game_data["actions"].forEach((action, index) => {
        if (action["type"] == "undo") {
          if (action["action_id"]) {
              undo_blocks.push([action["action_id"] + 1, action["id"]]);
              last_valid_id = action["action_id"];
          } else {
              undo_blocks.push([last_valid_id, last_valid_id]);
              last_valid_id -= 1;
          }
        } else if (action["type"] == "redo") {
          undo_blocks.pop()[1]
          last_valid_id = action["id"]
        } else {
          last_valid_id = action["id"]
        }
    });
    return new Set(undo_blocks.flatMap((e) => { return new Array(e[1] - e[0]).fill(1).map( (_, i) => i+e[0] )}))
}

console.log(games)

console.log("autorouter is good enough", Object.entries(games).filter((x) => x[1].auto_lose == 0).map((x) => x[0]))
console.log("autorouter isn't good enough", Object.entries(games).filter((x) => x[1].auto_lose != 0).map((x) => x[0]))
