# IONOS DynDNS Updater with Gotify Support

A robust, zero-dependency (except `curl` & `jq`) Bash script to automatically update **all** DNS A-records in your IONOS account to match your current public IP address. It supports multiple zones, intelligent change detection, and optional Push notifications via Gotify.

## 🚀 Features

  * **Auto-Discovery:** Automatically fetches all DNS zones and records from your IONOS account.
  * **Smart Updates:** Checks your current public IP against the DNS records. Updates are only triggered if the IP has actually changed (saving API calls).
  * **Gotify Notifications:** (Optional) Sends a push notification to your mobile/desktop when an update occurs.
  * **Bulk Updates:** Updates multiple subdomains and zones in a single API transaction.
  * **Logging:** detailed logging to `~/.config/ionos-dyndns/dyndns.log`.
  * **Safety:** Includes a confirmation mode for testing before automating.

## 📋 Prerequisites

This script requires standard Linux tools. Most are pre-installed, but you **must** have `jq` installed for JSON parsing.

```bash
# Debian / Ubuntu
sudo apt update && sudo apt install curl jq

# RHEL / CentOS / Fedora
sudo dnf install curl jq

# Alpine
apk add curl jq
```

## 🛠️ Installation

1.  **Download the script:**
    Save the script content to a file, for example, `ionos-dyndns.sh`.

2.  **Make it executable:**

    ```bash
    chmod +x ionos-dyndns.sh
    ```

3.  **Move to a permanent location (Optional):**

    ```bash
    mv ionos-dyndns.sh /usr/local/bin/ionos-dyndns
    ```

## ⚙️ Configuration

The script includes an interactive setup wizard to generate the necessary configuration files.

1.  **Run the setup:**

    ```bash
    ./ionos-dyndns.sh --setup
    ```

2.  **Follow the prompts:**

      * **IONOS API Key:** You can generate this at [developer.hosting.ionos.com](https://developer.hosting.ionos.com/).
      * **Gotify (Optional):** Enter your Gotify Server URL and App Token if you want notifications.

*Configuration files are stored securely in `~/.config/ionos-dyndns/`.*

## 📖 Usage

### Automatic Mode (Default)

Checks the IP and updates records only if they are outdated. No output to console unless there is an error (logs are saved to file).

```bash
./ionos-dyndns.sh
```

### Force Mode

Updates all records regardless of whether the IP has changed. Useful for forcing a sync.

```bash
./ionos-dyndns.sh --force
```

### Interactive / Confirmation Mode

Asks for confirmation before every API call. Useful for testing and seeing exactly what the script will do.

```bash
./ionos-dyndns.sh --confirm
```

### View Help

```bash
./ionos-dyndns.sh --help
```

## 🔔 Gotify Integration

If configured, the script will send a Markdown-formatted notification **only** when:

1.  The Public IP has changed.
2.  The DNS update was successfully triggered at IONOS.

**Configuration File Manual Edit:**
You can manually edit `~/.config/ionos-dyndns/gotify.conf`:

```bash
GOTIFY_URL="https://push.yourdomain.com"
GOTIFY_TOKEN="A123456789..."
```

## 🤖 Automation (Cron Job)

To keep your DNS updated automatically, add the script to your crontab.

1.  Open crontab:

    ```bash
    crontab -e
    ```

2.  Add the following line to run every 10 minutes:

    ```bash
    */10 * * * * /path/to/ionos-dyndns.sh
    ```

*(Note: The script writes logs to `~/.config/ionos-dyndns/dyndns.log`, so you don't need to redirect output in the cron job unless you want to capture stderr).*

## 📂 File Structure

The script creates the following directory structure:

```text
$HOME/.config/ionos-dyndns/
├── api_key       # Your IONOS API Key (chmod 600)
├── gotify.conf   # Gotify URL and Token (chmod 600)
└── dyndns.log    # Execution logs
```

