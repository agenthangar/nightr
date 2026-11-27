# Physical battery acceptance

The signed candidate workflow requires a passing battery run for the same DMG. Open the **battery-acceptance** job for the result. Its receipt identifies the commit, Actions run and attempt, version, DMG SHA-256, installed app CDHash, starting charge, cutoff, first observed low charge, hold release, system sleep, full wake and resumed protection. A successful signing job alone leaves physical acceptance pending. Use only the DMG whose digest matches the passing receipt for release.

### Enroll the fixture once

Use a dedicated MacBook with an open lid and a dedicated, logged-in console account. For unattended testing, connect its only charging source to the controlled outlet. With a regular outlet set `"chargerMode": "cable"` and omit both charger commands. The coordinator posts notices to unplug and reconnect the cable and evaluates the same sleep and wake evidence. The separate always-on coordinator needs Git, Python 3.11+, SSH/SCP, and network access to the fixture. Pin the MacBook's SSH host key and configure an SSH alias for the console account with noninteractive authentication. Verify reachability on battery. Keep fixture configuration and credentials on the lab machines.

1. Register the coordinator in the organization runner group `nightr-battery-lab` with the label `nightr-battery-coordinator`. Restrict the group to the selected workflow `agenthangar/nightr/.github/workflows/release.yml@refs/heads/main`. The runner account has access to the charger and fixture login. Use the workflow restriction when granting access to this public repository. [GitHub runner group access](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/manage-access)
2. On the MacBook, provision Python 3 on the noninteractive SSH path, Apple command-line tools with signing and staple verification, and the signed, directly installed desktop app. Use a dedicated test installation with the power helper authorized. Verify `nightr setup --check`, then leave the controller running with protection stopped. Provide the lab account's noninteractive installation route for the verified signed PKG through the system CLI installer. The installer checks the signatures, version, source revision, package receipt and code hash and reopens the app before testing.
3. Install the repository's `scripts/battery_lab_wake.py` at `/Library/PrivilegedHelperTools/ai.nightr.battery-lab-wake.py` as root:wheel mode 0755. Provision sudo for the test login to invoke the fixed CLT Python executable with `-IS`, that exact protected file, and its validated timer arguments. The adapter tracks one owned wake event in `/private/var/db/nightr-battery-lab`. Cleanup cancels that specific event.
4. Create the root-owned, read-only-to-the-test-account marker `/Library/Application Support/NightrBatteryLab/fixture.json` with the fields below. Set `hardwareUUID` from IOPlatformUUID and `login` to the dedicated console account. Set `wakeVerified` to true only after confirming this MacBook reaches a full wake with the timer on battery. Administrative setup is confined to enrollment.
5. On the coordinator, install `/etc/nightr-battery-lab.json`, owned by root and readable by the runner account. For a timed relay, verify the configured outlet powers only the MacBook and restores charging when its timer expires. Once the fixture and runner are ready, set the repository variable `NIGHTR_BATTERY_LAB_READY=true`. The existing independent `NIGHTR_TEAM_ID` variable supplies the expected signing team.

The MacBook marker uses these fields. The example values are synthetic.

```json
{
  "fixtureID": "battery-01",
  "hardwareUUID": "REPLACE-WITH-LAB-HARDWARE-UUID",
  "login": "batterytest",
  "wakeVerified": false,
  "wakeCommand": ["/usr/bin/sudo", "-n", "/Library/Developer/CommandLineTools/usr/bin/python3", "-IS", "/Library/PrivilegedHelperTools/ai.nightr.battery-lab-wake.py"]
}
```

For a regular outlet, the complete coordinator configuration has three fields.

```json
{"fixtureID": "battery-01", "sshHost": "nightr-test-mac", "chargerMode": "cable"}
```

For unattended operation, the following example uses a Shelly Gen2 switch. Substitute the actual lab SSH alias and device controls at enrollment. The charger commands are argument arrays. The runner fills in `{seconds}` and expects each command to exit successfully only after the relay accepts it. Shelly's `toggle_after` sets a timer in the switch. [Shelly Switch.Set](https://shelly-api-docs.shelly.cloud/gen2/ComponentsAndServices/Switch/)

```json
{
  "fixtureID": "battery-01",
  "sshHost": "nightr-test-mac",
  "chargerOn": ["/usr/bin/curl", "--fail", "--silent", "--max-time", "10", "http://lab-switch.example/rpc/Switch.Set?id=0&on=true"],
  "chargerOffFor": ["/usr/bin/curl", "--fail", "--silent", "--max-time", "10", "http://lab-switch.example/rpc/Switch.Set?id=0&on=false&toggle_after={seconds}"]
}
```

### What a run proves

The run starts at 40% charge or higher on AC. Nightr takes its normal hold. A separate bounded `caffeinate -i` assertion continues to block idle sleep. Temporary CLI settings set the cutoff one point below the starting charge. The runner allows up to 30 minutes for discharge. In cable mode it prompts for unplugging and reconnection. In timed-relay mode it switches the outlet itself. It checks for Nightr's below-cutoff observation, release of its named assertion, software-requested system sleep on battery within 60 seconds of the first observed low reading, and a subsequent full wake. Loss of SSH triggers a request to restore charging. The runner waits for power-log evidence. The wake timer is armed before discharge. Passing also requires protection to resume on AC and cleanup to return Nightr to stopped intent.

A timeout, missing evidence, or cleanup failure fails the job. In timed-relay mode the outlet restores charging if the coordinator stops. With a regular outlet, reconnect the cable if the run is interrupted. If the fixture loses contact beyond the wake deadline, restore connectivity and charging and use the checked-out probe from that run with `cleanup --fixture-id ID --run-id RUN_ID-ATTEMPT` under its test login. The probe retains a private recovery record and checks ownership before cleanup. The next candidate requires its own passing receipt.
