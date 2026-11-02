cask "typing-stats" do
  auto_updates true
  version "0.0.31"
  sha256 "e34c75616337a9496933e48cb8643991e557140e0b99828ecf051c913506f824"

  url "https://github.com/rauchg/typing-stats/releases/download/v#{version}/TypingStats.zip"
  name "Typing Stats"
  desc "Track your daily keystroke statistics"
  homepage "https://github.com/rauchg/typing-stats"

  app "Typing Stats.app"

  zap trash: [
    "~/Library/Application Support/TypingStats",
    "~/Library/Preferences/com.typing-stats.app.plist",
  ]
end
