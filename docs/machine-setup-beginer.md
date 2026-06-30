# nextGPU Machine Setup Guide (Beginner Edition)

**Start here if this is your first time setting up a nextGPU machine.** No prior knowledge assumed.

**Prefer screenshots?** See [setup-beginer.md](setup-beginer.md).

---

## What you're actually building

In plain terms: you're turning a Windows PC with a GPU into a machine that other people can rent and stream games on remotely (like a cloud gaming PC you host). When you're done, a renter will be able to open a link in their browser and play games running on this physical machine, from anywhere.

To make that work, this guide walks you through installing a few pieces of software that each do one job:


| Piece                    | What it does in one sentence                                                                                         |
| ------------------------ | -------------------------------------------------------------------------------------------------------------------- |
| **NextGPU Controller**   | The app you click buttons in. It runs all the setup scripts for you.                                                 |
| **RegisterMachine**      | The big one-time setup script. Installs drivers, sets up streaming, and tells nextGPU's servers this machine exists. |
| **Sunshine + Moonlight** | The actual game-streaming software (Sunshine runs on this PC, Moonlight is what the renter uses to watch/play).      |
| **Cloudflare Tunnel**    | Gives your machine a public web address without you touching your router.                                            |
| **PlayNite**             | Scans for installed games (Steam, Epic, etc.) and makes them show up as launchable options for the renter.           |


You only do most of this **once per machine**. After that, it mostly runs itself.

**Time estimate:** 1–2 hours for a first machine, including a couple of reboots. Most of that is waiting for downloads and installs, not active work.

---

## Table of contents

1. [Before you touch anything](#1-before-you-touch-anything)
2. [Start from a clean machine](#2-start-from-a-clean-machine)
3. [Get the files onto the machine](#3-get-the-files-onto-the-machine)
4. [Install and open the Controller app](#4-install-and-open-the-controller-app)
5. [Step 1: Check the machine is ready](#step-1-check-the-machine-is-ready)
6. [Step 2: Prepare a drive for games](#step-2-prepare-a-drive-for-games)
7. [Step 3: Download the official games/apps](#step-3-download-the-official-gamesapps)
8. [Step 4: Set up NVIDIA (driver and settings)](#step-4-set-up-nvidia-driver-and-settings)
9. [Step 5: Run the main setup (RegisterMachine)](#step-5-run-the-main-setup-registermachine)
10. [Step 6: Set up renter storage (the U: drive)](#step-6-set-up-renter-storage-the-u-drive)
11. [Step 7: Add games with PlayNite](#step-7-add-games-with-playnite)
12. [Step 8: Publish your game list to AWS](#step-8-publish-your-game-list-to-aws)
13. [Step 9: Final check before going live](#step-9-final-check-before-going-live)
14. [If something goes wrong](#if-something-goes-wrong)
15. [Glossary](#glossary)
16. [Where to find things later](#where-to-find-things-later)

---

## 1. Before you touch anything

### Check the machine qualifies


| Need                                               | Why                                                                                                              |
| -------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| Windows 10 or 11 (64-bit)                          | This whole system is Windows-only.                                                                               |
| An NVIDIA GPU                                      | Needed for smooth game streaming.                                                                                |
| Normal internet access                             | It needs to reach GitHub, Cloudflare, and AWS — standard outbound web access, nothing special to configure.      |
| You can log in as Administrator                    | Every step below needs admin rights. If you only have a standard account, get the admin password first.          |
| Free space on a second drive (or room to make one) | Games and apps get stored separately from Windows itself. We'll create this drive in Step 2 if it doesn't exist. |


> A heads-up, not a blocker: on some newer Windows installs (specifically "11 24H2" or "Server 2025"), one of the audio drivers later in this guide is known to occasionally fail to install cleanly. It won't stop you from finishing setup — streaming video and renter access still work fine. We'll point it out again when it comes up.

### Have these ready (write them down somewhere before you start)

Think of this as your shopping list. You'll be asked for these mid-way through Step 5, and stopping to go find them partway through is the most common reason people redo this step.


| What                        | What it's for                                                                             | Where it usually comes from                                                                 |
| --------------------------- | ----------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| Cloudflare API Token        | Lets this machine create its own public web address                                       | Contact with NextGPU                                                                        |
| Cloudflare Account ID       | Identifies which Cloudflare account owns that address                                     | Contact with NextGPU                                                                        |
| nextGPU API Key             | Lets this machine register itself with nextGPU's servers                                  | Contact with NextGPU                                                                        |
| A name for this computer    | What you'll see in the dashboard (e.g: `NEXTGPU-105`)                                     | Contact with NextGPU                                                                        |
| Listing price               | What this machine will be listed/rented for (e.g: 4000)                                   | Contact with NextGPU                                                                        |
| Vendor ID *(optional)*      | Only needed if you're a vendor partner — otherwise just press Enter to skip               | Your nextGPU contact, if applicable                                                         |
| Your current admin username | The setup will rename this account — see note below(eg: ezycloudx-admin, pcrender, admin) | Already on your machine(check what username you log-on open cmd and type: "echo %USERNAME%" |


**Important about that last one:** the setup process renames your current admin account to `NextGPU-Authority` and creates a brand new everyday account called `nextGPU` (this is the one renters actually use). Your admin login still works after the rename — it just has a new name and becomes the "owner" account that can shut the machine down. Nothing is deleted.

You'll also want these later, for Step 6 — it's fine to gather them now or just before that step:


| What                       | What it's for                                                       |
| -------------------------- | ------------------------------------------------------------------- |
| S3 Access Key + Secret Key | Lets each renter get their own private storage drive on the machine |


**One rule that matters everywhere in this guide:** never paste real tokens, keys, or passwords into a shared chat, ticket, or document. Treat them like a password, because they function like one.

---

## 2. Decide whether to clean the machine first (optional)

**This step is optional — evaluate your machine before deciding.** Unlike the rest of this guide, there's no single right answer here; it depends on the machine itself.

**Why this is even a question:** every application this machine will run during a rental session — game launchers, streaming software, everything — gets installed and managed by nextGPU's own setup in the steps that follow. Leftover software from before (old apps, trial programs, a previous owner's installs) doesn't strictly block setup, but it can take up disk space and occasionally conflicts with the streaming or game-detection steps later.

### When it's worth cleaning

- The machine has a lot of unrelated software already installed, especially anything that auto-starts, runs in the background, or does its own screen capture / remote access (these are the most likely to conflict with Sunshine later).
- Disk space is tight and old software is eating into the room you'll want for games on `Z:`.
- You don't know the machine's history — it was handed down, bought used, or repurposed from something unrelated.

### When you can reasonably skip it

- The machine is a known, purpose-built rig with fast NVMe storage and you specifically want to put it into service for nextGPU as-is — in that case, the speed and capacity of the hardware is the main reason you're using it, and a full wipe mostly costs you time without much benefit.
- It's already a fresh or near-fresh Windows install with nothing but standard manufacturer software on it.
- You've already confirmed nothing on the machine conflicts with streaming software (no other remote-desktop or capture tools running).

If you're not sure which bucket your machine falls into, erring toward cleaning is the safer default — but it's your call, not a hard requirement.

**Recommended tool:** HiBit Uninstaller — download it from: [https://v30.x8top.net/tmp082020/cf/soft/2018/3/ba/4/hibit-uninstaller_1424.exe](https://v30.x8top.net/tmp082020/cf/soft/2018/3/ba/4/hibit-uninstaller_1424.exe)

### Uninstall existing applications individually

1. Download and install HiBit Uninstaller from the link above.
2. Open it and review the list of installed applications.
3. Remove anything not required for Windows itself to run. When in doubt about whether something is safe to remove, leave it — you can always remove it later, but a mistakenly-deleted system component can mean reinstalling Windows anyway.
4. Reboot once you're done clearing applications, before moving on to Step 3.

**Either way, confirm before continuing:** Windows boots cleanly, you can log in as Administrator, and there's no leftover game launcher, streaming tool, or remote-access software still running in the background that might compete with what nextGPU installs next.

---

## 3. Get the files onto the machine

1. Download the setup package: [RegisterMachine.zip](https://github.com/bluefml1/nextGPU-corescripts/releases/latest/download/RegisterMachine.zip) (always points to the latest release)
2. Extract the zip somewhere permanent on the **local C: drive** — or **Downloads folder**
3. **Pick a folder now and don't move it later.** Once Step 7 (PlayNite) runs, several scripts remember this exact location. Moving the folder afterward will break things.

That's the whole step — you now have a folder full of scripts and an app installer sitting on the machine.

---

## 4. Install and open the Controller app

The Controller is a small desktop app with buttons for everything below. You technically *can* run every step by typing commands instead, but there's no reason to — the app runs the exact same scripts and shows you what's happening as it goes. This guide assumes you're using it.

1. Open the folder from Step 2.
2. Double-click `NextGPU.bat`.
3. If Windows shows a security prompt asking to let it make changes, click **Yes** — the app needs Administrator rights to do anything useful.
4. Sign in with the credentials from your nextGPU onboarding email or admin. *(If you don't have these yet, that's expected for a brand-new install — contact your admin before continuing)*

Once you're in, you'll land on a **Get Started** page with the same nine steps listed in this guide, each with its own button. From here on, this guide explains what each button actually does, what to expect, and what "success" looks like — so you're never just clicking and hoping.

---

## Step 1: Check the machine is ready

**What you're doing:** running a quick scan that confirms nothing is missing from the setup folder before any real changes happen. Think of it as a pre-flight check.

**Click:** `Run Layout Test`

**What "success" looks like:**

- A list of checks, each ending in `[OK]`
- A final line reading **"All layout checks passed"**

**If something fails:**

- Most often, the folder from Step 2 didn't extract completely. Delete it and re-extract the zip fresh.
- Double check you're running this on the Windows machine itself, not from a Mac or Linux computer.

You can't usefully continue past this step until it passes — fix any `[FAIL]` lines first.

---

## Step 2: Prepare a drive for games

**What you're doing:** Windows normally has everything on one drive (`C:`). This step creates (or resizes) a separate drive — typically called `Z:` — specifically for games and apps, so they're kept separate from the operating system.

**Click:** `Open Disk Management`, then `Run CHKDSK Repair`

### 2a. Quick health check first(Must be running)

Click **Run CHKDSK Repair**. This scans your drive for filesystem errors before resizing anything — skipping this is how partition resizing goes wrong. You'll be asked whether to check one drive or all of them; checking all is the safer default. If it asks to schedule a repair on next reboot, allow it and restart when convenient.

### 2b. Create the games drive

From the Disk Management page, click **Shrink Volume (Extend Existing or Create New)**. You'll be asked:

1. Which drive to take space from (usually `C:`)
2. How much space, in GB, to take
3. Whether to extend an existing `Z:` drive or create a brand new one

If you're not sure how much space to allocate: Windows will recommend for you how many GBs to allocated

**When you're done, your drives should look roughly like this:**


| Drive | What lives there                                     |
| ----- | ---------------------------------------------------- |
| `C:`  | Windows itself — leave this alone going forward      |
| `Z:`  | Games, Adobe apps, and the scripts that launch games |


**If the shrink fails:** this almost always means Windows has something "pinned" to the end of the drive that can't move. Three usual fixes, in order: turn off hibernation (search Windows for "Command Prompt", run `powercfg /h off`), move your page file off that drive, or delete System Restore points on that drive. Reboot and try the shrink again after any of these.

---

## Step 3: Download the official games/apps

**What you're doing:** pulling pre-approved game and app installers from nextGPU's official storage, and unpacking them onto your new `Z:` drive.

**Click:** `Sync Game/Apps`

You'll be shown a list of available archives and can pick which ones to download. Each one downloads with a visible progress bar and gets automatically unpacked to the right folder on `Z:` (for example, `Z:\Steam` or `Z:\Adobe`).

**What "success" looks like:**

- The games/apps you picked now have folders on `Z:`
- No lines in the log mentioning `[FAIL]`

**Don't worry if:** you see a warning about "winget" returning a non-zero result, or a "remote preflight" warning — both are harmless as long as files actually show up afterward. Only worry if a folder you selected is genuinely empty.

You can come back and re-run this step later any time new official content is added.

---

## Step 4: Set up NVIDIA (driver and settings)

**What you're doing:** making sure the graphics card has the latest official NVIDIA driver installed, then setting a few global options so games stream smoothly at a steady frame rate. This step is done on the machine itself — there is no button for it in the Controller app.

**Do this before Step 5 (RegisterMachine).** A reboot after installing the driver is normal; RegisterMachine will ask for another reboot later anyway.

### 4a. Install the latest Game Ready driver

Use the **NVIDIA App** on the machine — no need to download the driver from a website.

1. Press the **Windows** key and type **NVIDIA** — open **NVIDIA App**.
  - Don't see it? Install **NVIDIA App** from the **Microsoft Store** (search the Store for "NVIDIA"), then open it.
  - You can also right-click the desktop and choose **NVIDIA App**, or click the NVIDIA icon in the system tray (bottom-right, near the clock).
2. In NVIDIA App, open the **Drivers** tab (sometimes labeled **Driver**).
3. Click **Check for updates** (or **Download** if an update is already listed).
4. When the download finishes, click **Install** and choose **Express Installation** (recommended).
5. **Reboot when the installer asks you to** (or reboot manually if it doesn't prompt).

**What "success" looks like:**

- After reboot, NVIDIA App opens normally and the **Drivers** tab shows your GPU is up to date (no pending update).
- In **Device Manager** → **Display adapters**, your GPU shows without a yellow warning icon.

**If the install fails:** close NVIDIA App, reopen it, and try **Check for updates** again. If it keeps failing, use **Custom install** in the driver installer and check **Perform a clean installation**, then reboot.

### 4b. Set global 3D settings

These three settings keep frame rates predictable for remote streaming — renters get a smooth picture without unnecessary lag from VSync.

Stay in **NVIDIA App** (the same app you used in 4a):

1. In the left sidebar, click **Graphics**.
2. At the top of the page, open the **Global Settings** tab (not a single game or app).
3. Scroll through the list and set each option below. If you don't see a setting right away, scroll further down the page.


| Setting                                   | Set it to                       |
| ----------------------------------------- | ------------------------------- |
| **Max Frame Rate**                        | **On** — then enter **120** FPS |
| **Vertical sync**                         | **Off**                         |
| **Background Application Max Frame Rate** | **120 FPS**                     |


1. **Background Application Max Frame Rate** may be under **Legacy settings** — if you don't see it in the main list, scroll to the bottom and click **Show Legacy Settings**, then set it to **120 FPS**.

NVIDIA App usually saves as you change each value. Close and reopen **Graphics** → **Global Settings** to double-check all three stuck.

**Quick check:** all three values should still show **120 FPS** / **Off** / **120 FPS** after you reopen the Global Settings page.

**Why these values?** 120 FPS matches a common streaming target; turning VSync off avoids extra input delay; capping background apps stops Windows clutter from stealing GPU time while a renter is playing.

---

## Step 5: Run the main setup (RegisterMachine)

This is the big one — it's the longest step and the one that needs your full attention, since it'll ask you questions partway through.

**What you're doing:** installing the virtual display and audio drivers, installing the streaming software (Sunshine/Moonlight), setting up your public web address via Cloudflare, and telling nextGPU's servers that this machine exists and is ready to be listed.

**Have your list from [Section 1](#have-these-ready-write-them-down-somewhere-before-you-start) open and ready before you click the button** — you'll be asked for most of it within the first minute.

**Click:** `Run RegisterMachine`

1. Maybe Windows will ask for permission to make changes (if you're not in the administrator priviledge)  — click **Yes**.
2. A console window opens and starts asking questions one at a time: Cloudflare token, Cloudflare account ID, your nextGPU API key, a name for the computer, the listing price, an optional vendor ID, and your current admin username.


| What                        | What it's for                                                                             | Where it usually comes from                                                                  |
| --------------------------- | ----------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| Cloudflare API Token        | Lets this machine create its own public web address                                       | Contact with NextGPU                                                                         |
| Cloudflare Account ID       | Identifies which Cloudflare account owns that address                                     | Contact with NextGPU                                                                         |
| nextGPU API Key             | Lets this machine register itself with nextGPU's servers                                  | Contact with NextGPU                                                                         |
| A name for this computer    | What you'll see in the dashboard (e.g: `NEXTGPU-105`)                                     | Contact with NextGPU                                                                         |
| Listing price               | What this machine will be listed/rented for (e.g: 4000)                                   | Contact with NextGPU                                                                         |
| Vendor ID *(optional)*      | Only needed if you're a vendor partner — otherwise just press Enter to skip               | Your nextGPU contact, if applicable                                                          |
| Your current admin username | The setup will rename this account — see note below(eg: ezycloudx-admin, pcrender, admin) | Already on your machine(check what username you log-on open cmd and type: "echo %USERNAME%") |


1. It'll show you a summary of everything you entered. Check it, then type **Y** to confirm and continue.
2. Type "Y" when console showing: Installing Virtual Display Driver and Virtual Audio Driver...
  Install or refresh VDD/VAD now? [Y/N]
3. From here, it runs unattended for a while. You can watch progress with `Open Provisioning Logs` if you're curious, but you don't need to do anything else until it finishes.

**Don't worry if:** you're input wrong credentials or mismatch something, just turn off the console window and click to run Step 5 again

### What's actually happening behind the scenes (for context, not action)


| Stage                   | In plain terms                                                                                                               |
| ----------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| Setup check             | Confirms you're an admin and looks at your hardware                                                                          |
| Virtual display & audio | Installs drivers that let the machine "pretend" to have a monitor and speakers plugged in, even with nobody physically there |
| Streaming setup         | Installs Sunshine (the streaming server) and pairs it with Moonlight (the viewer)                                            |
| Public address          | Creates your Cloudflare tunnel and DNS so the machine has a web address                                                      |
| Registration            | Sends your hardware details to nextGPU's servers and gets this machine officially listed                                     |
| Background services     | Sets up the small always-running programs that keep things healthy (heartbeat, auto-repair)                                  |
| Wrap-up                 | Applies the wallpaper, renames your admin account, creates the `nextGPU` rental account                                      |


### When it finishes

1. **Reboot when it tells you to.** This isn't optional — several of the changes (drivers, the account rename) only take full effect after a restart.
2. After rebooting, log in **once**, either via Remote Desktop or directly on the machine with username: NextGPU-Authority.
3. Open the file `domain.txt` (in your setup folder) — it has a web address in it. Open that address in a browser and confirm Moonlight Web loads.

---

## Step 6: Set up renter storage (the U: drive)

**Requires:** Step 5 must be fully finished first (it creates a file called `domain.txt` that this step needs).

**What you're doing:** giving each renter their own private storage drive, labeled `U:`, that shows up automatically about 22 seconds after they log in.

**Click:** `One-Click S3 Setup`

This installs a couple of small background tools and quietly sets up two scheduled tasks that handle mounting the drive whenever the `nextGPU` rental account logs in — you won't need to trigger this manually going forward.

### Enter your storage credentials

You'll need the S3 Access Key and Secret Key from your list in Section 1. The app will prompt you for these directly — you don't need to manually edit any files.

### Confirm it worked

1. Log in as the `nextGPU` account (the rental account created in Step 5) — either directly or through a Moonlight session.
2. Wait about 22 seconds.
3. A `U:` drive should appear, labeled with something like "**{Name}'s Storage**".

**If it doesn't appear:** open the **User Storage** page in the Controller and click **Diagnose & fix** — this checks the most common causes (permissions, the storage tool itself, and the connection) and fixes what it can automatically.

> **Note for later:** if you ever delete and recreate the `nextGPU` account, don't redo this whole step — there's a smaller "Sync" option instead. Worth knowing now, not urgent yet.

---

## Step 7: Add games with PlayNite

**Requires:** Step 5 must be finished (this step needs Sunshine, which Step 5 installs).

**What you're doing:** scanning for games already installed on the machine (Steam, Epic, etc.) and making them show up as launchable options for renters in Moonlight.

**Before you click anything**, make sure the games you want available are actually installed on this machine already — this step finds existing installs, it doesn't install games for you.

**Click:** `Run PlayNite Setup`

1. Pick a folder to install PlayNite into (e.g. `Z:\Playnite`).
2. It downloads and unpacks PlayNite automatically.
3. It scans your drives for Steam and Epic games — no login to those services needed, it just looks at what's on disk.
4. After scan Steam and Epic it will showing options to scan allowlist choose specific "disk or folder" to make it scan faster or scan "all disks"
5. It exports everything it found to Sunshine, so it shows up for renters.
6. It installs a small helper (PlayNiteWatcher) that automatically closes the stream when a renter exits a game, rather than leaving it running.
7. It automatically **pushes the Moonlight game list to AWS** using `domain.txt` (from Step 5) — no separate Step 8 click needed on first setup.

**What "success" looks like:**

- The games you expected show up when you check the **PlayNite** tab in the Controller via launch PlayNite to see what app installed in playnite application
- The setup console ends with `Moonlight games pushed to AWS successfully` (or `SUCCESS` from the update API)

**Added new games since running this?** Click `Update-PlayniteLibraries` (also on the PlayNite tab) and re-export — you don't need to redo the whole setup. Then run **Push Moonlight Games to AWS** (User Experience tab) so the backend stays in sync.

---

## Step 8: Publish your game list to AWS

**Requires:** Steps 5 and 7 finished — this needs `domain.txt` (from RegisterMachine) and games already exported to Moonlight (from PlayNite).

**What you're doing:** sending the current Moonlight game list to nextGPU's servers so renters can see and launch those games from the dashboard — not just on this machine locally.

**On first setup:** Step 7 (**Run PlayNite Setup**) does this automatically at the end when `-WithSunshine` runs (the default **Run PlayNite Setup** button). You only need this step manually when you add or change games later.

**Click:** **Push Moonlight Games to AWS** (Controller → **User Experience** tab)

1. Confirm the `computer_name` and `publicIP` shown in the prompt (they are read from `domain.txt`).
2. A console window opens, fetches apps from Moonlight Web, and posts them to AWS — leave it open until it finishes.

**What "success" looks like:**

- The console ends with `SUCCESS` and lists the games that were added (or updated).
- The game count matches what you expect from Step 7.

**If it fails:**

- **"Could not reach Moonlight Web"** — make sure the `moonlight-web` service is running (you'll verify this again in Step 9).
- **"domain.txt is missing COMPUTER_NAME or PUBLIC_IP"** — re-run Step 5 (RegisterMachine) or fix `domain.txt` at the repo root.
- **"No apps returned"** — go back to Step 7 and confirm games show up in Moonlight first, then try again.

**Added or changed games later?** Click **Push Moonlight Games to AWS** again — you do not need to redo the full PlayNite setup.

---

## Step 9: Final check before going live

**Requires:** Step 8 finished (game list published to AWS).

**What you're doing:** going through a short checklist to confirm everything from Steps 1–8 is actually working together, before you hand the machine off to a renter.

**Click:** `Run Wallpaper Verification`, then work through this list:


| #   | Check                           | What "good" looks like                                                                       |
| --- | ------------------------------- | -------------------------------------------------------------------------------------------- |
| 1   | Streaming starts                | Log in as `nextGPU`; a test stream connects through Moonlight without a black screen         |
| 2   | Wallpaper looks right           | The verification script reports `[OK]`, and the desktop image isn't stretched or cropped     |
| 3   | Drivers are present             | Virtual display and audio devices show up in Device Manager                                  |
| 4   | Background services are running | `cloudflared`, `moonlight-web`, `gpu-heartbeat`, and `auto-repair` are all listed as running |
| 5   | Renter storage works            | Log in as `nextGPU`; the `U:` drive appears with the right label                             |
| 6   | Games show up                   | The PlayNite-exported games appear in the Moonlight app list                                 |
| 7   | No alarming errors in the logs  | A quick skim of the recent logs doesn't show repeated failures                               |


### Test it like a renter would

1. Open `domain.txt`, copy the web address, and open it in a browser — ideally from a different device.
2. Confirm Moonlight Web loads, the machine shows up, and a test stream actually starts.

### One more reboot, then recheck

After everything passes once, reboot the machine one more time and recheck items 1, 4, and 5 specifically. Display setup and the `U:` drive are the two things most likely to behave differently after a cold boot versus right after setup — better to catch that now than after a renter is already connected.

Once all seven checks pass after that reboot, the machine is ready to list.

---

## If something goes wrong

Find the symptom you're seeing below.

### Black screen when streaming starts

**Likely cause:** the display software isn't fully warmed up yet.

**Try, in order:**

1. Open the Controller and use the option to start Sunshine within the active session (not as a background service).
2. From the **Sunshine** page, restart its API / refresh the display.
3. Re-apply the wallpaper.
4. If you just installed the virtual display driver, reboot — this is often the actual fix.

### Virtual display not showing up

#### Manual fix: point Sunshine at the VDD display

Use this when streaming shows a black screen, the wrong monitor, or Sunshine never picked up the virtual display automatically.

**Part 1 — Find the VDD `device_id`**

1. Make sure **Sunshine is running** (from the Controller **Sunshine** page, use **Restart Sunshine (Service)** if you're unsure).
2. Open a browser on the machine and go to `**https://localhost:47990`**.
  - Your browser will warn about the certificate — that's normal for a local Sunshine install. Choose **Advanced** → **Proceed to localhost** (wording varies by browser).
3. Open the **Troubleshooting** tab, then open the **Logs** section (Sunshine shows its log output here).
4. Press **Ctrl+F** (Find on page) and search for `**device_id`** inside the log text.
5. Look through the matches until you find the block for the **virtual display (VDD)**. You're on the right one when you see `"friendly_name": "VDD by MTT"` and `"primary": true` inside `"info"`.
  A correct VDD entry in the logs looks like this (your `device_id` and resolution may differ slightly):

```json
{
  "device_id": "{222d7a6c-39bc-5175-89c3-3ae777fe8f15}",
  "display_name": "\\\\.\\DISPLAY48",
  "edid": {
    "manufacturer_id": "MTT",
    "product_code": "1337",
    "serial_number": 518463207
  },
  "friendly_name": "VDD by MTT",
  "info": {
    "hdr_state": "Disabled",
    "origin_point": {
      "x": 0,
      "y": 0
    },
    "primary": true,
    "refresh_rate": {
      "type": "rational",
      "value": {
        "denominator": 1,
        "numerator": 120
      }
    },
    "resolution": {
      "height": 1440,
      "width": 2560
    },
    "resolution_scale": {
      "type": "rational",
      "value": {
        "denominator": 100,
        "numerator": 125
      }
    }
  }
}
```

1. Copy the `**device_id**` from that block — including the curly braces. From the example above, copy:
  `{222d7a6c-39bc-5175-89c3-3ae777fe8f15}`

> **Tip:** If several displays appear in the logs, always use the VDD entry with `**"primary": true`**. Physical monitors usually have different `friendly_name` values and are not what you want for headless streaming.

**Part 2 — Paste it into Sunshine**

1. In the same Sunshine web UI (`https://localhost:47990`), open the **Configuration** tab.
2. Go to **Audio/Video**.
3. Find **Display ID** (sometimes labeled **Output Name** in older builds).
4. Paste the `device_id` you copied.
5. Click **Save**, then **Apply** (or restart Sunshine from the Controller **Sunshine** page).

**What "success" looks like:** a test Moonlight stream shows the desktop on the virtual display, not a black screen. If it still fails, re-run **Sunshine API Restart** from the Controller and try streaming again.

### No audio during a stream

**Likely cause:** the virtual audio driver didn't install correctly (common on some Windows 11 24H2 machines).

**Fix:** In the Controller, open the **VDD/VAD** page and click **Install VAD Fallback**. Let it finish, then start a new test stream and check audio again.

### "rclone install failed" warning, but things seem to work

This usually means the tool was already installed and the installer just reported it oddly. Open a terminal and type `rclone version` — if that shows a version number, it's fine, ignore the warning.

### Desktop wallpaper looks wrong or icons are visible

1. Re-run the wallpaper setup option.
2. Run the wallpaper verification check.
3. If using Moonlight/virtual display, make sure Sunshine was started within the session — the wallpaper sometimes applies on a short delay tied to that.

### Can't shrink the drive in Step 2

Turn off hibernation, move or shrink the page file, and clear System Restore points on that drive — then reboot and try again. (Same fix as in Step 2 above, repeated here since it's the most common stuck point.)

### PlayNite imported zero games

**Likely cause:** the game-finding tool isn't running, or your drives haven't been indexed.

**Try:** start the "Everything" search tool, let it index your drives, then re-run the import from the PlayNite tab.

### Renter storage (U:) missing

1. Open **User Storage** → **Diagnose & fix**.
2. Try **Mount U: for Moonlight**.
3. If that doesn't work, re-run the Step 6 setup — no reboot needed for this one.

### Push Moonlight Games to AWS failed

**Likely causes:** Moonlight Web is not running, no games were exported yet, or `domain.txt` is incomplete.

**Try, in order:**

1. Confirm the `moonlight-web` service is running (Step 9, checklist item 4).
2. Confirm games appear in the Moonlight app list locally (Step 7 / Step 9, checklist item 6).
3. Open `domain.txt` and verify `COMPUTER_NAME=` and `PUBLIC_IP=` are filled in.
4. Re-run **Push Moonlight Games to AWS** from the **User Experience** tab.
5. **If it still fails:** open `**https://localhost:47990`** in a browser (accept the certificate warning if prompted), go to the **Troubleshooting** tab, and **restart Sunshine**. Then try **Push Moonlight Games to AWS** again.

---

## Glossary

Quick definitions if a term in this guide is unfamiliar.


| Term                      | Plain-English meaning                                                                              |
| ------------------------- | -------------------------------------------------------------------------------------------------- |
| **Sunshine**              | The software running on this PC that captures the screen and streams it out.                       |
| **Moonlight**             | The viewer app a renter uses to watch and control the stream.                                      |
| **Virtual display / VDD** | Software that makes Windows think a monitor is plugged in, even when nobody's physically there.    |
| **Virtual audio / VAD**   | Same idea, but for speakers/audio output.                                                          |
| **Cloudflare Tunnel**     | A way to give this machine a public web address without configuring your router.                   |
| **rclone / WinFsp**       | Background tools that let a cloud storage bucket appear as a normal drive letter in Windows.       |
| **PlayNite**              | A game/app library manager that finds installed games/apps and lists them for streaming.           |
| `**domain.txt`**          | A file created after Step 5 containing this machine's public web address.                          |
| `**NextGPU-Authority`**   | Your original admin account, renamed — the only account that can shut down or restart the machine. |
| `**nextGPU`** (account)   | The everyday account renters actually use during their session.                                    |


---

## Where to find things later

### Key logs

If you need to dig into a problem, these are the most useful files (all inside your setup folder unless noted otherwise):


| Log file                                        | What it tells you                                                        |
| ----------------------------------------------- | ------------------------------------------------------------------------ |
| `logs\register_api_log.txt`                     | What was sent to nextGPU's servers during Step 5, and how they responded |
| `logs\VDD-VAD.log`                              | Virtual display/audio driver install details                             |
| `logs\heartbeat.log`                            | Ongoing status updates from this machine                                 |
| `logs\auto-repair.log`                          | Anything the machine fixed automatically on its own                      |
| `logs\sync-games-apps-*.log`                    | Details from the Step 3 game download                                    |
| `%ProgramData%\nextGPU\logs\user-storage-*.log` | Renter storage (`U:`) connection details                                 |


### Other guides in this repo


| Document                                    | What's in it                                                               |
| ------------------------------------------- | -------------------------------------------------------------------------- |
| `README.md`                                 | Technical internals — useful once you're comfortable and want to go deeper |
| `user-storage-recreate-flow.md`             | What to do if you delete and recreate the `nextGPU` account                |
| `PlayNiteWatcher/docs/Playnite-EndToEnd.md` | Full detail on the PlayNite automation                                     |


### If you ever need to undo everything

Preview what would be removed, without actually removing it:

```
uninstall-all.bat whatif
```

Actually remove everything:

```
uninstall-all.bat force
```

This does **not** remove your Cloudflare DNS/tunnel or rename `NextGPU-Authority` back — those need to be cleaned up separately if you want them gone too. Reboot after uninstalling.