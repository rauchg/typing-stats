cask "typing-stats" do
  version "0.0.10"
  sha256 "1a8f4ab4bb001779c54a6ab645f1f3e61775460a0cf7f303d640c3a30c8a2b5a"

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
