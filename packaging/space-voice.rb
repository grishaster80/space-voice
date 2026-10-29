cask "space-voice" do
  version "__VERSION__"
  sha256 "__SHA256__"

  url "https://github.com/__REPO__/releases/download/v#{version}/SpaceVoice-#{version}.zip"
  name "Space Voice"
  desc "Tap Space, then hold Space in any text field to dictate"
  homepage "https://github.com/__REPO__"

  depends_on macos: ">= :sonoma"

  app "SpaceVoice.app"

  # The app is not notarized: without this Gatekeeper refuses to open it.
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/SpaceVoice.app"]
  end

  uninstall quit: "io.github.grishaster80.spacevoice"

  zap trash: [
    "~/Library/Preferences/io.github.grishaster80.spacevoice.plist",
  ]
end
