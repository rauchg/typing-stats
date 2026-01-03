cask "typing-stats" do
  version "0.0.9"
  sha256 "64c657ce05f5cca13e487646b0b879903bdcef6638fb6fdb87243a0a5231c356"

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
