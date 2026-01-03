cask "typing-stats" do
  auto_updates true
  version "0.0.18"
  sha256 "aa2d786ed29b7bd2e8b1c552e1705121b1c9465c6a937f600243fd9d52618d07"

  url "https://github.com/rauchg/typing-stats/releases/download/v#{version}/TypingStats.zip"
  name "Typing Stats"
  desc "Track your daily keystroke statistics"
  homepage "https://github.com/rauchg/typing-stats"

  app "Typing Stats.app"

  postflight do
    system "xattr", "-cr", "#{appdir}/Typing Stats.app"
  end

  zap trash: [
    "~/Library/Application Support/TypingStats",
    "~/Library/Preferences/com.typing-stats.app.plist",
  ]
end
