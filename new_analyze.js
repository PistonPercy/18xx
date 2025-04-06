const fs = require('node:fs');

snabbdom = {
    init: function() {}
}

Big = require('./public/assets/server.js').Big

let games_times = {}
games = {}
game_id_to_title = {}
buggy = {}
opt_fails_overlap = {}
opt_fails_invalid_combo_became_valid = {}


let output = JSON.parse(fs.readFileSync('output.json', 'utf8'))
let new_output = JSON.parse(fs.readFileSync('output.opt_flags.json', 'utf8'))

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
          new_win: 0,
          new_lose: 0,
          equal: 0,
          new_time: 0,
          old_time: 0,
          total_runs: 0,
        }
    }

    for (let action of game_data["actions"]) {
        let ids = game_data["id"]+':'+action["id"];
        if (action["type"] != "run_routes") continue;
        if (!output[ids]) continue;
        if (!new_output[ids]) continue;
        if (output[ids].revenue == "UNDO" ||
new_output[ids].revenue == "UNDO"
        ) {
          if (new_output[ids].revenue != output[ids].revenue) {
            console.log("undos unsynced", ids)
            //throw "undo is unsynced";
          }
          continue;
        }
        let new_rev = new_output[ids].revenue
        let old_rev = output[ids].revenue

        // bail if one of the runs didn't finish
        if ((new Set([old_rev, new_rev]).intersection(new Set(["DNF", "DNR"]))).size != 0) continue;

        if (typeof new_rev !== 'number' || typeof old_rev !== 'number') {
          console.log(new_rev, old_rev);
          throw 'we got invalid revs';
        }
        if (new_rev > old_rev) {
            games[title].new_win += 1
        } else if (new_rev == old_rev) {
            games[title].equal += 1
        } else {
            console.log(ids);
            games[title].new_lose += 1
        }

        if (new_output[ids].time_seconds > 20) {
          if(title=="1846") console.log("slowid", ids)
        games_times[title] ??= {new:0, old:0}
            games_times[title].new += 1;
        }
        if (output[ids].time_seconds > 20) {
        games_times[title] ??= {new:0, old:0}
            games_times[title].old += 1;
        }

        if (new_output[ids].OPT_FAIL_overlap) {
            opt_fails_overlap[title] = true
        }
        if (new_output[ids].OPT_FAIL_invalid_combo_became_valid) {
            if (title == "1846") console.log("this is the weird id", ids);
            opt_fails_invalid_combo_became_valid[title] = true
        }
        if (new_output[ids].BUG_revenue_bigger_than_estimate) {
            buggy[title] = true
        }
    }
}

console.log(games)

console.log("new autorouter is good enough", Object.entries(games).filter((x) => x[1].new_lose == 0).map((x) => x[0]))
console.log("new autorouter isn't good enough", Object.entries(games).filter((x) => x[1].new_lose != 0).map((x) => x[0]))

console.log("new autorouter is better", Object.entries(games).filter((x) => x[1].new_win != 0).map((x) => x[0]))
console.log("new autorouter isn't better", Object.entries(games).filter((x) => x[1].new_win == 0).map((x) => x[0]))

console.log("buggy", buggy);
console.log("opt_fails_overlap", opt_fails_overlap);
console.log("opt_fails_invalid_combo_became_valid", opt_fails_invalid_combo_became_valid);

console.log("slow runs", games_times);
