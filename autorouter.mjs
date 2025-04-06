import fs from 'node:fs';
import process from 'node:process';
import { execFile} from 'node:child_process';

let output_file = 'output.json';

let output = load_output(output_file);
let count = 0;
let number_running = 0;

async function main() {
  let target_count = process.argv.length - 2;
  let current_count = 0;
  for (let game_file of process.argv.slice(2)) {
    await run(game_file);
    current_count += 1;
    console.log(current_count, target_count);
  }
}
await main();
while (number_running != 0) {
  await sleep(100)
}
write_output(output_file);

async function run(game_file) {
    let game_data_str = fs.readFileSync(game_file, 'utf8')
    let game_data = JSON.parse(game_data_str)
    if (game_data["error"]) return;

    for (let action of game_data["actions"]) {
        if (action["type"] != "run_routes") continue;
        if (output[game_data["id"]+':'+action["id"]]) continue;
        while (number_running == 2) await sleep(100)
        number_running += 1
        execFile('node', ['./autorouter_single.js', game_file, action["id"] + ""], {
            stdio: 'pipe',
            // todo: using this makes it so we can't detect what happened timeout: 0,

            // Use utf8 encoding for stdio pipes
            encoding: 'utf8',
        }, (error, stdout, stderr) => {
            number_running -= 1;
            try {
                output[game_data["id"]+':'+action["id"]] = JSON.parse(stdout.match(new RegExp('output:(.*)'))[1])
            } catch (e) {
                console.log("failed to run", game_data["id"]+':'+action["id"])
                output[game_data["id"]+':'+action["id"]] = {revenue: "DNR"}
            }
            let number_keys = Object.keys(output).length;
            if (count + 10 < number_keys) {
              write_output(output_file);
              count = number_keys;
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
