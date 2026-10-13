# Uploading Ranked 5s Ban Advisor to GitHub

This folder has two parts:

- **repo/** goes into the GitHub repository (the code, README, images, license).
- **release/** goes on the Releases page (the zip people download).

## 1. Create the repository
1. Sign up or sign in at github.com.
2. Click **+** (top right) → **New repository**.
3. Repository name: `ranked-5s-ban-advisor`. Choose **Public**. Leave every "Initialize" box unticked.
4. Click **Create repository**.

## 2. Upload the repo files
1. On the new repository page, click **uploading an existing file**.
2. Open the **repo** folder on your PC, select everything inside it (Ctrl+A), and drag it onto the GitHub page. Folders (src, docs) upload with it.
3. Commit message: `First version`. Click **Commit changes**.
4. Check the front page shows the banner and README.

## 3. Publish the download (Release)
1. On the repository page, click **Releases** (right side) → **Create a new release**.
2. **Choose a tag** → type `v1.6.3` → **Create new tag**.
3. Title: `Ranked 5s Ban Advisor v1.6.3`.
4. Description: paste everything from **release/RELEASE-NOTES.md**.
5. Drag **release/Ranked5sBanAdvisor.zip** into the "Attach binaries" box.
6. Click **Publish release**.

## 4. Add a VirusTotal scan (builds trust)
1. Go to virustotal.com → **Choose file** → pick **Ranked5sBanAdvisor.zip**.
2. When the scan finishes, copy the page link.
3. Back on GitHub: **Releases** → the release → **Edit** (pencil icon) → add a line `VirusTotal scan: <link>` → **Update release**.

## 5. Finishing touches
- **Description:** on the repository page, click the gear next to **About**, add "Free champ select scouting for League of Legends", and tick **Releases**.
- **Social preview:** Settings → General → Social preview → upload `docs/images/banner.jpg`.

## Donations: later, after Riot approves
Donations are turned off for now. Riot only allows them once the app is **Approved** or **Acknowledged** on the developer portal. When that happens, ask Claude to turn the Ko-fi button back on and add the GitHub **Sponsor** button.

## 6. Use the link
Your Product URL for the Riot application is:
`https://github.com/YOUR-GITHUB-NAME/ranked-5s-ban-advisor`

## Updating later
Upload changed files with **Add file → Upload files**, then create a new release (for example `v1.6.4`) with the new zip.
