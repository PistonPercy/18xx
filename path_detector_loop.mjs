import fs from 'node:fs';
import process from 'node:process';
import { execFile} from 'node:child_process';
import { DatabaseSync } from 'node:sqlite';
const database = new DatabaseSync('output.db');

database.exec(`
  CREATE TABLE IF NOT EXISTS data(
    game_id INTEGER,
    action_id INTEGER,
    title TEXT,
    walk TEXT,
    valid_route TEXT,
    output TEXT,
    error TEXT
  ) STRICT
`);

const insert = database.prepare('INSERT INTO data VALUES (?, ?, ?, ?, ?, ?, ?)');
const exists = database.prepare('SELECT 1 FROM data WHERE game_id = ? AND action_id = ?')


let count = 0;
let number_running = 0;

async function main() {
  let target_count = process.argv.length - 2;
  let current_count = 0;
  for (let game_file of process.argv.slice(2)) {
    await run(game_file);
    current_count += 1;
    console.error(current_count, target_count);
  }
}
await main();
while (number_running != 0) {
  await sleep(100)
}

async function run(game_file) {
    let game_data_str = fs.readFileSync(game_file, 'utf8')
    let game_data = JSON.parse(game_data_str)
    if (game_data["error"]) return;

    for (let action of game_data["actions"]) {
        if (action["type"] != "run_routes") continue;
        if (exists.get(game_data["id"], action["id"])) {
          console.log("skipping", game_data["id"], action["id"])
          continue;
        }
        while (number_running == 2) await sleep(100)
        console.log("running", game_data["id"], action["id"])
        number_running += 1
        execFile('node', ['./path_detector.js', game_file, action["id"] + ""], {
            stdio: 'pipe',
            // todo: using this makes it so we can't detect what happened timeout: 0,

            // Use utf8 encoding for stdio pipes
            encoding: 'utf8',
        }, (error, stdout, stderr) => {
            number_running -= 1;
            try {
                let output = stdout.match(new RegExp('output:(.*)'))[1]
                let valid_route = "unknown";
                if (stdout.includes("valid_route:")) {
                  valid_route = stdout.match(new RegExp('valid_route:(.*)'))[1]
                }
                let walk = "unknown";
                if (stdout.includes("walk:")) {
                  walk = stdout.match(new RegExp('walk:(.*)'))[1]
                }
                insert.run(game_data["id"], action["id"], game_data["title"], walk, valid_route, output, null);
            } catch (e) {
                insert.run(game_data["id"], action["id"], game_data["title"], "unknown", "unknown", "{}", e.toString());
            }
        })
    }
}

function load_output(file) {
    return JSON.parse(fs.readFileSync(file, 'utf8'))
}

function write_output(file) {
    return fs.writeFileSync(file, JSON.stringify(output))
}

function sleep(ms) {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}
