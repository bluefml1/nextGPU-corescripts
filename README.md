# Gaming setup remotely

A lightweight Windows batch script that sends periodic heartbeat signals to your backend, reporting the machine's public/private IPs, computer name, and online status. Designed for secure GPU rental fleets with Cloudflare Tunnel integration.

---
✅ Entire operation is self-contained in `Downloads`—ideal for temporary or rental environments.
## 🚀 Quick Start

1. **Download** the latest release:
   - Go to [Releases](https://github.com/Nguyenanvu202/gamingsetup-.git)
   - Download and extract `gaming setup beta 1.0.zip`

2. **Change the heartbeat time**
   - Open heartbeat-only.bat at the end of file change number at this:
     ```
     timeout /t 270 /nobreak >nul
     ```
3. **Run the agent**:
   - Double-click `gaming setup running as service.bat`
   - Or run in Command Prompt (as user or admin):
     ```cmd
     Running `gaming setup beta 1.0.bat` with Administrator
     Input your  **Cloudflare API Token** and **ACCOUNT_ID**:
     ```

The script will:
- Wait for network connectivity
- Detect your public and private IP addresses, GPU information
- Send an register machine to lambda function
- Send a heartbeat to your AWS backend at your chosen interval




# How it work
# GPU Remote Gaming Setup with Moonlight, Sunshine, and Cloudflare Tunnel

This project automates the deployment of a secure, remotely accessible gaming workstation using **Sunshine** (host), **Moonlight Web** (client), **Cloudflare Tunnel**, and **AWS DynamoDB** for machine registration and heartbeat tracking. All components run as Windows services for reliability and background operation.

---

## 🧩 Overview

The system enables secure remote GPU access by:
- Hosting the game stream via **Sunshine**.
- Serving the Moonlight Web client via a background service.
- Exposing the service securely over the internet using **Cloudflare Tunnel** (no public IP exposure).
- Registering and monitoring each machine in **AWS DynamoDB** with a heartbeat mechanism.

---

## 🚀 Setup Workflow

### Initial Machine Setup (One-time)

1. **Install and Start Sunshine**  
   Sunshine is installed and configured to serve game streaming over localhost.
   Scans and add all games that have in this GPU to sunshine via Add-SteamGames.ps1
   Add 4 files(autohotkey setup) to sunshine for strict user interact outside application 
3. **Deploy Moonlight Web as a Windows Service**  
   Using [NSSM (Non-Sucking Service Manager)](https://nssm.cc/), Moonlight Web is run in the background, serving the web client on a local port.

4. **Verify Cloudflare API Token**  
   A secure token (stored outside scripts) is validated for DNS and Tunnel management permissions.

5. **Gather Machine Metadata**  
   - Computer name  
   - Public IP (via external API)  
   - Private IP (local network)

6. **Generate Unique DNS Identifier**  
   A deterministic ID is created from the public IP and computer name for consistent subdomain mapping (e.g., `gpu-abc123.nguyentranviethung.org`).

7. **Create & Configure Cloudflare Tunnel**  
   A named tunnel is created in Cloudflare, routing traffic to the local Moonlight Web port.

8. **Install `cloudflared` as a Windows Service**  
   Ensures the tunnel stays active across reboots.

9. **Collect GPU Information**  
   GPU model, driver version, and other hardware details are captured programmatically.

10. **Register Machine in DynamoDB**  
   All metadata (GPU info, IPs, encoded domain, etc.) is sent to an AWS DynamoDB table for centralized tracking.

11. **Generate Encoded Domain & Save**  
    The full access URL (e.g., base64-encoded subdomain) is written to `domain.txt` for use by heartbeat scripts.

12. **Install Heartbeat Script as Service**  
    The `heartbeat-only.bat` script is installed as a Windows service via NSSM.

13. **Start Heartbeat Service**  
    Begins periodic status reporting.

---

## ❤️ Heartbeat Process (`heartbeat-only.bat`)

Runs every 10 seconds as a background service:

1. **Loads Context**  
   Reads:
   - Encoded domain (from `domain.txt`)
   - Current public & private IPs
   - Computer name

2. **Auto-Update Moonlight Web (Optional)**  
   - Checks the latest Moonlight Web release on GitHub.
   - Compares with local version (stored in `version.txt`).
   - If outdated, replaces static files with the latest from GitHub.

3. **Send Heartbeat to DynamoDB**  
   - Updates the machine’s status in DynamoDB using the encoded domain as a unique key.
   - Handles dynamic public IP changes gracefully.
   - Includes timestamp, connectivity status, and GPU availability.

> ✅ This ensures your GPU rental service always knows which machines are online and accessible.


---

## 🛠️ Technologies Used

- **Sunshine** – Open-source game stream host (alternative to NVIDIA GameStream)
- **Moonlight Web** – Browser-based Moonlight client
- **Cloudflare Tunnel (`cloudflared`)** – Secure, reverse tunnel without exposing IPs
- **NSSM** – Run batch scripts and apps as Windows services
- **AWS DynamoDB** – Serverless database for machine registration & status
- **Batch Scripting** – Full automation without PowerShell or VBScript
- **GitHub API** – For version checking and auto-updates

---

## 📁 File Structure (Key Files)
├── gaming setup running as service.bat # Main setup script (Steps 1–12)
├── heartbeat-only.bat # Periodic status updater (runs as service)
├── domain.txt # Stores encoded access domain
├── moonlight-web
│ └── version.txt # Tracks current Moonlight Web version
└── nssm.exe (example) # Service manager 

