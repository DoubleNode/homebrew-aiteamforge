class Aiteamforge < Formula
  desc "AITeamForge - AI-powered multi-team development infrastructure"
  homepage "https://github.com/DoubleNode/homebrew-aiteamforge"
  url "https://github.com/DoubleNode/homebrew-aiteamforge.git",
      tag: "v1.3.7"
  license "MIT"
  version "1.3.7"

  # Core dependencies required for aiteamforge to function
  depends_on "python@3"
  depends_on "node"
  depends_on "jq"
  depends_on "gh"
  depends_on "git"
  depends_on "tmux"
  depends_on :macos => :big_sur # iTerm2 and macOS-specific features

  # Optional dependencies for advanced features
  uses_from_macos "rsync" # For sync scripts

  def install
    # Install all core files to libexec (framework location)
    libexec.install Dir["*"]

    # Create bin stubs for main commands
    (bin/"aiteamforge").write <<~EOS
      #!/bin/bash
      # AITeamForge CLI dispatcher
      AITEAMFORGE_HOME="#{libexec}"
      export AITEAMFORGE_HOME
      exec "#{libexec}/bin/aiteamforge-cli.sh" "$@"
    EOS

    (bin/"aiteamforge-setup").write <<~EOS
      #!/bin/bash
      # AITeamForge interactive setup wizard
      AITEAMFORGE_HOME="#{libexec}"
      export AITEAMFORGE_HOME
      exec "#{libexec}/bin/aiteamforge-setup.sh" "$@"
    EOS

    (bin/"aiteamforge-doctor").write <<~EOS
      #!/bin/bash
      # AITeamForge health check and diagnostics
      AITEAMFORGE_HOME="#{libexec}"
      export AITEAMFORGE_HOME
      exec "#{libexec}/bin/aiteamforge-doctor.sh" "$@"
    EOS

    chmod 0755, bin/"aiteamforge"
    chmod 0755, bin/"aiteamforge-setup"
    chmod 0755, bin/"aiteamforge-doctor"
  end

  def post_install
    # Create installation marker (delete first to allow reinstall/upgrade)
    marker = HOMEBREW_PREFIX/"var/aiteamforge/.installed"
    (HOMEBREW_PREFIX/"var/aiteamforge").mkpath
    marker.delete if marker.exist?
    marker.write "#{version}\n#{Time.now}"

    # Suggest running setup
    ohai "AITeamForge framework installed successfully"
    ohai "Run 'aiteamforge setup' to configure your environment"
  end

  def caveats
    <<~EOS
      AITeamForge has been installed to:
        #{libexec}

      Available commands:
        aiteamforge setup     - Interactive setup wizard
        aiteamforge doctor    - Health check and diagnostics
        aiteamforge status    - Show current environment status
        aiteamforge upgrade   - Upgrade components
        aiteamforge help      - Show help information

      To get started:
        1. Run: aiteamforge setup
        2. Follow the interactive wizard to:
           - Install iTerm2 (if needed)
           - Install Claude Code (if needed)
           - Select teams to configure
           - Set up LCARS Kanban system
           - Configure terminal environment

      The setup wizard will guide you through creating your
      team environment in ~/aiteamforge (or custom location).

      IMPORTANT: The formula installs the FRAMEWORK only.
      Run 'aiteamforge setup' to create your working environment.

      For troubleshooting: aiteamforge doctor
      For documentation: #{libexec}/docs/
    EOS
  end

  test do
    # Verify main commands exist and are executable
    assert_predicate bin/"aiteamforge", :exist?
    assert_predicate bin/"aiteamforge-setup", :exist?

    # Verify core directories exist (libexec/ subdir mirrors repo structure)
    assert_predicate libexec/"libexec/commands", :exist?
    assert_predicate libexec/"libexec/installers", :exist?
    assert_predicate libexec/"libexec/lib", :exist?
    assert_predicate libexec/"share/templates", :exist?
    assert_predicate libexec/"share/teams", :exist?

    # Verify library files exist
    assert_predicate libexec/"libexec/lib/common.sh", :exist?
    assert_predicate libexec/"libexec/lib/config.sh", :exist?
    assert_predicate libexec/"libexec/lib/wizard-ui.sh", :exist?

    # Test that setup wizard shows version
    system "#{bin}/aiteamforge-setup", "--help"
  end
end
