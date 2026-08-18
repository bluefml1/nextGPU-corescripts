# nextGPU Setup (Beginner — Visual Guide)

> Screenshot walkthrough. Full explanations and troubleshooting: [machine-setup-beginer.md](machine-setup-beginer.md)

**Start here if you want pictures for every click.** Time estimate: 1–2 hours including reboots.

---

## Table of contents

1. [Before you start](#before-you-start) *(includes NVIDIA driver — do before the Controller)*
2. [Optional: clean the machine](#optional-clean-the-machine)
3. [Get the files](#get-the-files)
4. [Install the Controller](#install-the-controller)
5. [Step 1 — Check the machine (STEP 01)](#step-1--check-the-machine-step-01)
6. [Step 2 — Prepare Z: drive (STEP 02)](#step-2--prepare-z-drive-step-02)
7. [Step 3 — Sync games/apps (STEP 03)](#step-3--sync-gamesapps-step-03)
8. [Step 4 — RegisterMachine (STEP 04)](#step-4--registermachine-step-04)
9. [Step 5 — Renter storage U: (STEP 05)](#step-5--renter-storage-u-step-05)
10. [Step 6 — PlayNite (STEP 06)](#step-6--playnite-step-06)
11. [Step 7 — Final check (STEP 07)](#step-7--final-check-step-07)
12. [If something goes wrong](#if-something-goes-wrong)
13. [More help](#more-help)

**Controller alignment:** Guide Steps 1–7 match **Get Started → STEP 01–07** in the NextGPU app. NVIDIA setup is **before** the Controller (no app button).

---

## Before you start

### Machine requirements

| Need | Why |
| ---- | --- |
| Windows 10 or 11 (64-bit) | Windows-only setup |
| NVIDIA GPU | Game streaming |
| Internet access | GitHub, Cloudflare, AWS |
| Administrator login | Every step needs admin |
| Room for a data drive | We create `Z:` in Step 2 (STEP 02) if needed |

### NVIDIA driver and settings *(before the Controller)*

**No app button** — on the machine itself, **before** you open `NextGPU.bat` / Get Started.

#### Turn off Windows Firewall first

Driver installs can fail or hang when Windows Firewall is on.

1. Open **Windows Defender Firewall** (search Windows, or **Control Panel → System and Security → Windows Defender Firewall**).
2. Left sidebar → **Turn Windows Defender Firewall on or off**.
3. For **Private** and **Public**, choose **Turn off Windows Defender Firewall**.
4. Click **OK**. Both should show **Windows Defender Firewall state: Off**.

![Windows Defender Firewall — Off for Private and Public](images/setup-beginer/firewall-off.png)

#### Install Game Ready driver

1. Open **NVIDIA App** (Microsoft Store if missing).
2. **Drivers** → set type to **Game Ready Driver** (not Studio).
3. Install with **Express Installation** if an update is listed.
4. Reboot when prompted.

![NVIDIA App — Drivers (Game Ready Driver)](images/setup-beginer/nvidia-app-drivers.png)

#### Global Settings

**Graphics → Global Settings** only (not **Settings** gear, not **Program Settings**).

| Setting | Value |
| ------- | ----- |
| **Low Latency Mode** | **Ultra** |
| **Max Frame Rate** | **120 FPS** |
| **Vertical sync** | **Off** |
| **Background Application Max Frame Rate** | **120 FPS** *(Legacy settings if needed)* |

![NVIDIA App — Graphics → Global Settings](images/setup-beginer/nvidia-app-global-settings.png)

Details: [machine-setup-beginer.md#nvidia-driver-and-settings-before-the-controller](machine-setup-beginer.md#nvidia-driver-and-settings-before-the-controller)

### Have these ready before Step 4 (RegisterMachine)

| What | What it's for |
| ---- | ------------- |
| Cloudflare API Token | Public web address for this machine |
| Cloudflare Account ID | Cloudflare account that owns the tunnel |
| nextGPU API Key | Register machine with nextGPU servers |
| Computer name (e.g. `NEXTGPU-105`) | Dashboard label |
| Listing price (e.g. `4000`) | Rental price |
| Vendor ID *(optional)* | Press Enter to skip if not a vendor |
| Current admin username | Renamed to `NextGPU-Authority` during setup |

For **Step 5** (renter **U:** storage), also prepare **S3 Access Key + Secret Key**.

> Never paste real tokens into shared chats or documents. Use your own credentials — screenshots in this guide have sensitive values redacted.

**Accounts created by setup:** your admin becomes `NextGPU-Authority`; a new rental account `nextGPU` is created for renters.

---

## Optional: clean the machine

Skip this on a fresh Windows install. Use it when the PC has lots of leftover software or tight disk space.

**Tool:** [HiBit Uninstaller](https://v30.x8top.net/tmp082020/cf/soft/2018/3/ba/4/hibit-uninstaller_1424.exe)

1. Install HiBit and review installed apps.
2. Select apps to remove → right-click → **Uninstall Selected**.
3. Click **Start** on the bulk uninstall screen.
4. Reboot before continuing.

![HiBit — select programs to uninstall](images/setup-beginer/Picture1.png)

![HiBit — bulk uninstall, click Start](images/setup-beginer/Picture2.png)

---

## Get the files

1. Download [RegisterMachine.zip](https://github.com/bluefml1/nextGPU-corescripts/releases/latest/download/RegisterMachine.zip) 
2. Extract to a **permanent** folder on local `C:` or Downloads
3. **Do not move the folder later** — PlayNite and other scripts remember this path

---

## Install the Controller

1. Open the extracted folder.
2. Double-click **`NextGPU.bat`** (builds the app on first run — compiler warnings are OK).
3. Click **Yes** if Windows asks for admin permission.
4. Sign in when prompted.

![NextGPU.bat building the Controller](images/setup-beginer/Picture3.png)

![Build complete — run NextGPU.bat and sign in](images/setup-beginer/Picture24.png)

After sign-in you land on **Get Started** with **STEP 01–07** — Guide Steps 1–7 below match those cards.

---

## Step 1 — Check the machine (STEP 01)

**Controller:** STEP 01 — Validate Environment

**Button:** `Run Layout Test`

![Controller Get Started — Steps 01–04](images/setup-beginer/Picture4.png)

![Layout test — all checks OK](images/setup-beginer/Picture5.png)

**Success:** Every line shows `[OK]` and you see **All layout checks passed**.

**If it fails:** Re-extract the zip fresh. Fix every `[FAIL]` before continuing.

Details: [machine-setup-beginer.md#step-1-check-the-machine-is-ready](machine-setup-beginer.md#step-1-check-the-machine-is-ready)

---

## Step 2 — Prepare Z: drive (STEP 02)

**Controller:** STEP 02 — Disk Prep

**Buttons:** `Open Disk Management` → `Run CHKDSK Repair` → `Shrink Volume (Extend Existing or Create New)`

![Disk Management — CHKDSK and Shrink buttons](images/setup-beginer/Picture6.png)

### 2a. CHKDSK (run first)

1. Click **Run CHKDSK Repair**.
2. **Yes** = check all drives; **No** = pick one drive (usually `C`).
3. If prompted to restart for repairs, allow it.

![CHKDSK mode — all drives or one](images/setup-beginer/Picture7.png)

![Enter drive letter C](images/setup-beginer/Picture8.png)

![Schedule CHKDSK on restart](images/setup-beginer/Picture9.png)

### 2b. Shrink and create Z:

1. Click **Shrink Volume**.
2. Choose source drive (`C:`).
3. **No** = create a **new** partition (pick this if `Z:` does not exist yet).
4. Enter drive letter **`Z`**.
5. Restart when disk operation completes.

![Shrink — choose source drive C](images/setup-beginer/Picture10.png)

![Extend existing or create new — choose No for new Z:](images/setup-beginer/Picture13.png)

![Assign new drive letter Z](images/setup-beginer/Picture14.png)

![Disk operation complete — restart](images/setup-beginer/Picture15.png)

**Success:**

| Drive | Use |
| ----- | --- |
| `C:` | Windows |
| `Z:` | Games, apps, PlayNite |

**Shrink fails?** Run `powercfg /h off`, move page file, clear restore points, reboot, retry.

Details: [machine-setup-beginer.md#step-2-prepare-a-drive-for-games](machine-setup-beginer.md#step-2-prepare-a-drive-for-games)

---

## Step 3 — Sync games/apps (STEP 03)

**Controller:** STEP 03 — Sync Official Game Data

**Button:** `Sync Game/Apps`

1. If asked **Run CHKDSK / partition prep first?** → click **No** (you already did Step 2).
2. Wait for **rclone** and **WinFsp** to install if prompted.
3. Enter R2 credentials when asked (access key, secret key, Cloudflare Account ID).
4. Check the archives you want → OK.

![Sync start — skip CHKDSK if Step 2 done](images/setup-beginer/Picture16.png)

![Installing rclone](images/setup-beginer/Picture17.png)

![rclone download progress](images/setup-beginer/Picture18.png)

![R2 access key](images/setup-beginer/Picture19.png)

![R2 secret key](images/setup-beginer/Picture20.png)

![Cloudflare Account ID](images/setup-beginer/Picture21.png)

![Select release archives](images/setup-beginer/Picture22.png)

**Success:** Selected folders exist on `Z:` (e.g. `Z:\Steam`). No `[FAIL]` in the log.

Details: [machine-setup-beginer.md#step-3-download-the-official-gamesapps](machine-setup-beginer.md#step-3-download-the-official-gamesapps)

---

## Step 4 — RegisterMachine (STEP 04)

**Controller:** STEP 04 — Provision Full Host

**Button:** `Run RegisterMachine`

Have credentials from [Before you start](#before-you-start) ready.

1. Click **Yes** for admin permission.
2. Fill the **Register Machine — Configuration** form (secrets are masked):
   - **Install VDD/VAD** — **Yes** for headless streaming; **No** if this machine uses a physical monitor only
   - Cloudflare API Token, Account ID, API Key
   - Computer Name, Original Price, Vendor ID (optional)
   - **NextGPU-Admin password** — required; used for RunAsTool and session management (stored with DPAPI)
   - Admin account to rename → becomes `NextGPU-Authority`
3. Click **Run Register Machine**. An elevated console continues setup.
4. Wait for unattended provisioning to finish.
5. **Reboot** when prompted.
6. After reboot, open `domain.txt` and test the URL in a browser (Moonlight Web should load).

![Register Machine — Configuration (top: VDD + Cloudflare + API)](images/setup-beginer/register-machine-config-top.png)

![Register Machine — Configuration (bottom: price, NextGPU-Admin password, admin rename)](images/setup-beginer/register-machine-config-bottom.png)

**Wrong credentials?** Close the console / cancel, then run Step 4 again with corrected values.

Details: [machine-setup-beginer.md#step-4-run-the-main-setup-registermachine](machine-setup-beginer.md#step-4-run-the-main-setup-registermachine)

---

## Step 5 — Renter storage (U:) (STEP 05)

**Controller:** STEP 05 — Per-User S3 Storage (U:)

**Requires:** Step 4 finished (`domain.txt` exists).

**Button:** `One-Click S3 Setup`

1. Enter S3 Access Key and Secret Key when prompted.
2. Save credentials → **Y**; set machine env vars → **Y**.
3. Wait for setup to complete.

![S3 setup starting — domain.txt OK](images/setup-beginer/Picture25.png)

![Enter S3 keys — save credentials](images/setup-beginer/Picture26.png)

![Setup complete — U: auto-mounts on nextGPU logon](images/setup-beginer/Picture27.png)

**Confirm:** Log in as `nextGPU`, wait ~22 seconds — `U:` appears as **{Name}'s Storage**.

**Missing U:?** Controller → **User Storage** → **Diagnose & fix**.

Details: [machine-setup-beginer.md#step-5-set-up-renter-storage-the-u-drive](machine-setup-beginer.md#step-5-set-up-renter-storage-the-u-drive)

---

## Step 6 — PlayNite (STEP 06)

**Controller:** STEP 06 — Implement PlayNite

**Requires:** Step 4 finished (Sunshine installed).

In the Controller this is **STEP 06 — Implement PlayNite** (three buttons after setup finishes).

![STEP 06 — Implement PlayNite buttons](images/setup-beginer/step06-playnite-buttons.png)

**Buttons on the card:** **1. Run Playnite Setup**, **2. Setup Games & Apps**, **3. Host admin / Clean Session** (opens **Bypass** — admin account, service, Steam ACL, allowlist elevation, Clean Session).

### 1. Run Playnite Setup

**Button:** `1. Run Playnite Setup`

1. Pick install folder (e.g. `Z:\` — a `Playnite` subfolder is created).
2. Let it scan Steam/Epic and allowlisted desktop apps.
3. Choose scan scope: specific drive/folder or all non-system drives.
4. Setup exports games to Sunshine.

![Choose Z: for Playnite portable](images/setup-beginer/Picture28.png)

![Desktop apps scan scope](images/setup-beginer/Picture29.png)

### 2. Setup Games & Apps (assigned apps only)

**Button:** `2. Setup Games & Apps`

Use this for host layout only — **only for apps NextGPU assigned to this machine**. Clean Session lives in **§3 Host admin / Clean Session**.

**First-time order:** steps 1–2 here (arrange) → complete **§3 Bypass** → return for step 3 (push to AWS).

1. Open **Setup Games & Apps** → **Host Setup** tab.
2. Run **Setup Games & Apps** (arrange) and any sync actions required for your assigned titles. For Garena, this host layout already prepares the session template — you do **not** need **Seed Garena Template** later.

![Setup Games & Apps — Host Setup](images/setup-beginer/setup-games-apps-host.png)

3. **Publish the game list to AWS** — after host layout and **§3 Bypass** (allowlist + Clean Session if needed) for your assigned apps:

   1. Stay on **Setup Games & Apps** → **Host Setup** tab (same page as **Setup Games & Apps** arrange).
   2. Click **Push Moonlight Games to AWS**.
   3. Confirm `computer_name` and `publicIP` from `domain.txt` → **Yes**.
   4. Wait until the console shows **`SUCCESS`**.

   **When to run again:** after you add or change games on disk, re-run arrange/sync for those apps, then **Push Moonlight Games to AWS** again.

   **If push fails:** Controller → **Sunshine** → **Restart Sunshine**, then push again.

   ![Restart Sunshine before retrying Push to AWS](images/setup-beginer/restart-sunshine.png)

### 3. Host admin / Clean Session (Bypass — assigned apps only)

**Button:** `3. Host admin / Clean Session` *(opens **Bypass**)*

Configure **only apps on your assigned list**. Bypass has four tabs: **Setup**, **Allowlist**, **Clean Session**, **Tools & Logs**.

#### Setup tab — admin account, service, Steam ACL

![Bypass Setup tab](images/setup-beginer/bypass-setup-tab.png)

**NextGPU-Admin**

1. Click **Setup NextGPU-Admin**.
2. Check status:
   - **User Account: Ready**
   - **Credential: Stored**
3. If both are green (normal after Register Machine), click **Cancel** — no password needed.
4. If either is missing, enter the Register Machine password (12+ characters) → **Create & Store**.

![Setup NextGPU-Admin dialog](images/setup-beginer/bypass-setup-nextgpu-admin-dialog.png)

**NextGPU Service**

- **Status** should read **Running — pipe responsive** (green). Click **Refresh** if unsure.
- **Smoke Test** — pings the service pipe after changes.
- **Re-register (repair)** — refreshes service registration if launches fail.
- **Stop / Restart / Uninstall** — maintenance only; renters need the service running.

**Steam Library ACL**

Run once after Steam games are on disk, then again when you add titles:

| Button | When to use |
| --- | --- |
| **Grant ACL NextGPU-Admin for Steam** | First-time setup on this host |
| **Update ACL for new games** | After installing a new Steam game |
| **Steam ACL Status** | Check ACL without changing anything |
| **Revoke ACL NextGPU-Admin for Steam** | Decommission / troubleshooting only |

#### Allowlist tab — elevated launches

Games and desktop apps that must launch as admin (without a password prompt each rental).

![Bypass Allowlist tab](images/setup-beginer/bypass-allowlist-tab.png)

1. Open the **Allowlist** tab.
2. Enable **runAsAdmin** only for **assigned** titles that need admin (e.g. Garena FC Online). Leave unassigned rows and productivity apps unchecked.
3. Click **Export Admin launches** — re-exports Playnite + allowlist to Sunshine with `@ADMIN` markers. Confirm the warning (active Moonlight sessions may end).
4. If export fails, **close Playnite completely** and retry **Export Admin launches**. Only one Playnite instance can use `library\games.db` at a time.

**Other controls:** **Refresh** reloads the grid; **Delete Selected** removes entries; **Open in Notepad** edits `desktop-apps.allowlist.json` directly.

#### Clean Session tab — reset folders between rentals

Only if an assigned app needs its data folder wiped or replaced each rental (e.g. Garena).

![Bypass Clean Session tab](images/setup-beginer/bypass-clean-session-tab.png)

1. Click **Import JSON** — select the rules file NextGPU provided for this machine’s assigned apps.
2. Verify the rules table (id, title, action, target, source, stop, logon). Double-click cells to edit; use **Add / Update Rule** for one-offs.
3. Click **Register Session Folder Tasks** — wait until the console confirms logoff/logon tasks are registered.

![Session folder tasks registered](images/setup-beginer/session-folder-tasks-registered.png)

Skip **Seed Garena Template** if **Setup Games & Apps** host layout already prepared it.

| Button | When to use |
| --- | --- |
| **Seed Garena Template** | Only if Garena template was not created during host layout |
| **Open session-templates Folder** | Inspect golden replace sources under `ProgramData\nextGPU\session-templates` |
| **Run Logoff Rules (test)** | Dry-run logoff rules without ending a session |
| **Open Session Rules Log** | Troubleshoot rule execution |

> **Notice:** Session end runs folder rules **and** deletes/recreates `NextGPU-Admin`. Keep the Register Machine password — it is reused to recreate the account.

More detail: [session/clean-session.md](session/clean-session.md)

#### Tools & Logs tab

Quick links: **Open Steam Library Folder**, **Open ProgramData\\nextGPU**, **Open Session Rules Log**, **Open NextGPUService Log**, **Open Admin Setup Log**.

**Bypass success:** NextGPU-Admin Ready + Stored; service **Running — pipe responsive**; Steam ACL granted; **runAsAdmin** set and **Export Admin launches** done for assigned admin titles; Clean Session tasks registered when required.

Details: [machine-setup-beginer.md#step-6-add-games-with-playnite](machine-setup-beginer.md#step-6-add-games-with-playnite)

---

## Step 7 — Final check (STEP 07)

**Controller:** STEP 07 — Verify Host Is Ready

**Button:** `Run Wallpaper Verification`, then work through this list:

| # | Check | Good looks like |
| - | ----- | --------------- |
| 1 | Streaming | `nextGPU` login → Moonlight stream, no black screen; picture scales to client's requested resolution (see [wrong scaling](#stream-does-not-scale-to-requested-resolution)) |
| 2 | Wallpaper | Verification `[OK]`, image not stretched |
| 3 | Drivers | VDD/VAD in Device Manager |
| 4 | Services | `cloudflared`, `moonlight-web`, `gpu-heartbeat`, `auto-repair` running |
| 5 | U: drive | Appears after `nextGPU` logon (~22s) |
| 6 | Games | Show in Moonlight app list |
| 7 | Logs | No repeated failures |

### Test like a renter

1. Open `domain.txt` URL in a browser (ideally another device).
2. Confirm Moonlight Web loads and a test stream starts.

### One more reboot

Reboot once more and recheck streaming, services, and U: drive. When all seven checks pass, the machine is ready to list.

Details: [machine-setup-beginer.md#step-7-final-check-before-going-live](machine-setup-beginer.md#step-7-final-check-before-going-live)

---

## If something goes wrong

Find the symptom below. For full detail (VDD `device_id` JSON, log paths, etc.), see [machine-setup-beginer.md#if-something-goes-wrong](machine-setup-beginer.md#if-something-goes-wrong).

### Black screen when streaming starts

**Try, in order:**

1. Controller → start Sunshine within the active session (not only as a background service).
2. **Sunshine** page → restart API / refresh display.
3. Re-apply wallpaper.
4. Reboot if you just installed the virtual display driver.

### Stream does not scale to requested resolution

**Symptom:** Wrong size, letterboxing, or stretched picture — the stream does not match the resolution the renter chose in Moonlight.

**Fix:** Delete the default **Resolution Remapping** rule in Sunshine.

1. On the machine, open **`https://localhost:47990`** → **Configuration**.
2. Scroll to **Resolution Remapping**.
3. If you see a row like **Requested** `1920x1080` → **Final** `2560x1440`, click the **red trash icon** on that row to delete **both** the requested and final resolution fields (remove the whole row).
4. Leave **no remapping entries** unless you intentionally want to force a different host resolution.
5. Click **Save**, then restart Sunshine from the Controller **Sunshine** page if needed.
6. Start a new test stream and confirm the picture matches the client's requested resolution.

> Remapping only applies when **Optimize game settings** is enabled in the Moonlight client. If scaling still looks wrong after deleting the row, see [virtual display not showing up](#virtual-display-not-showing-up) in the full guide.

![Sunshine — delete Resolution Remapping if scaling is wrong](images/setup-beginer/Picture30.png)

### Virtual display not showing up

**Try, in order:**

1. Controller → **Install VDD/VAD** (or reinstall from **VDD/VAD** page).
2. Reboot.
3. Point Sunshine at the VDD display — find `device_id` in Sunshine logs (`https://localhost:47990` → **Troubleshooting** → **Logs**), paste into **Configuration** → **Audio/Video** → **Display ID**.

Full walkthrough: [machine-setup-beginer.md#manual-fix-point-sunshine-at-the-vdd-display](machine-setup-beginer.md#manual-fix-point-sunshine-at-the-vdd-display)

### No audio during a stream

**Likely cause:** Virtual Audio Driver (VAD) failed or is unsigned (Code 52 on some Windows 11 builds).

1. Controller → **VDD-VAD** → **Install VAD Fallback**.
2. Let the script finish — it may install **VB-CABLE** when the primary VAD is not usable.
3. **Reboot** if the script says the device is not ready yet.
4. In Sunshine (`https://localhost:47990` → **Configuration** → **Audio/Video**), set the audio device to **CABLE Input**.
5. Start a new test stream and check audio.

![VDD-VAD page — Install VAD Fallback](images/setup-beginer/vad-fallback-install.png)

### "rclone install failed" but sync still works

Run `rclone version` in a terminal. If a version prints, ignore the warning.

### Desktop wallpaper wrong or icons visible

1. Re-run wallpaper setup.
2. Run **Wallpaper Verification**.
3. Ensure Sunshine was started within the session.

### Can't shrink the drive (Step 2)

Run `powercfg /h off`, move page file off `C:`, clear System Restore points on that drive, reboot, retry shrink.

### PlayNite imported zero games

Start the **Everything** search tool, let drives index, then re-run import from the **PlayNite** tab.

### Renter storage (U:) missing

1. **User Storage** → **Diagnose & fix**.
2. **Mount U: for Moonlight**.
3. If still missing, re-run **One-Click S3 Setup** (Step 5).

### Push Moonlight Games to AWS failed

1. Confirm `moonlight-web` service is running.
2. Confirm games show in Moonlight locally.
3. Check `domain.txt` has `COMPUTER_NAME=` and `PUBLIC_IP=`.
4. Re-run **Push Moonlight Games to AWS** (**Setup Games & Apps** → **Host Setup** tab).
5. **Restart Sunshine** (Controller → **Sunshine** → **Restart Sunshine**), then push again.

![Restart Sunshine](images/setup-beginer/restart-sunshine.png)

---

## More help

| Topic | Link |
| ----- | ---- |
| Full troubleshooting (all symptoms) | [machine-setup-beginer.md#if-something-goes-wrong](machine-setup-beginer.md#if-something-goes-wrong) |
| Glossary | [machine-setup-beginer.md#glossary](machine-setup-beginer.md#glossary) |
| Log file locations | [machine-setup-beginer.md#key-logs](machine-setup-beginer.md#key-logs) |
| Technical reference | [README.md](README.md) |
