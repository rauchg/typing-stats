cask "typing-stats" do
  auto_updates true
  version "0.0.15"
  sha256 "bb9f97f25550003c8eaae5579443790c207364268902d95fb963e97a39d66ba3"

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
