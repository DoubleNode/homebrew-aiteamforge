class Aiteamforge < Formula
  desc "AITeamForge - Modular Agent Framework for composable AI development teams"
  homepage "https://aiteamforge.dev"
  url "https://github.com/DoubleNode/aiteamforge.git",
      tag: "v0.1.0"
  license "MIT"
  version "0.1.0"

  # Core dependencies
  depends_on "yq"          # YAML processing engine
  depends_on "jq"          # JSON processing
  depends_on "tmux"        # Terminal multiplexing
  depends_on "gh"          # GitHub CLI
  depends_on "git"         # Version control

  def install
    # Install framework to libexec (read-only, Homebrew-managed)
    libexec.install Dir["libexec/*"]

    # Create bin stubs for main commands
    (bin/"forge").write <<~EOS
      #!/bin/bash
      # AITeamForge CLI dispatcher
      FORGE_HOME="#{libexec}"
      export FORGE_HOME
      exec "#{libexec}/bin/forge-cli.sh" "$@"
    EOS

    (bin/"forge-setup").write <<~EOS
      #!/bin/bash
      # AITeamForge setup wizard
      FORGE_HOME="#{libexec}"
      export FORGE_HOME
      exec "#{libexec}/bin/forge-setup.sh" "$@"
    EOS

    (bin/"forge-doctor").write <<~EOS
      #!/bin/bash
      # AITeamForge health check
      FORGE_HOME="#{libexec}"
      export FORGE_HOME
      exec "#{libexec}/bin/forge-doctor.sh" "$@"
    EOS

    chmod 0755, bin/"forge"
    chmod 0755, bin/"forge-setup"
    chmod 0755, bin/"forge-doctor"

    # Make all scripts executable
    Dir["#{libexec}/bin/*.sh"].each { |f| chmod 0755, f }
    Dir["#{libexec}/lib/*.sh"].each { |f| chmod 0755, f }
  end

  def post_install
    # Create installation marker
    marker = HOMEBREW_PREFIX/"var/aiteamforge/.installed"
    (HOMEBREW_PREFIX/"var/aiteamforge").mkpath
    marker.delete if marker.exist?
    marker.write "#{version}\n#{Time.now}"

    ohai "AITeamForge installed successfully!"
    ohai "Run 'forge setup' to configure your environment"
  end

  def caveats
    <<~EOS
      AITeamForge has been installed to:
        #{libexec}

      Available commands:
        forge setup                Create your first crew
        forge create <name>        Create a new crew
        forge theme list           Browse available themes
        forge theme swap           Swap crew themes
        forge doctor               Health check

      To get started:
        1. Run: forge setup
        2. Follow the wizard to create your first crew
        3. Choose a purpose (iOS, web, etc.) and theme (TNG, House MD, etc.)

      Working directory: ~/aiteamforge/
      Extensions: ~/.aiteamforge/

      IMPORTANT: The formula installs the FRAMEWORK only.
      Run 'forge setup' to create your working environment.

      Documentation: https://aiteamforge.dev/docs
    EOS
  end

  test do
    assert_predicate bin/"forge", :exist?
    assert_predicate bin/"forge-setup", :exist?
    assert_predicate bin/"forge-doctor", :exist?

    # Verify core structure
    assert_predicate libexec/"bin/forge-cli.sh", :exist?
    assert_predicate libexec/"lib/common.sh", :exist?
    assert_predicate libexec/"lib/compiler.sh", :exist?
    assert_predicate libexec/"registry/specialties", :exist?
    assert_predicate libexec/"registry/themes", :exist?
    assert_predicate libexec/"registry/purposes", :exist?

    # Test version output
    assert_match "AITeamForge", shell_output("#{bin}/forge version")
  end
end
