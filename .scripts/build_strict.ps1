# Strict build for ChronoCOM on top of X2ModBuildCommon (dot-source after build_common.ps1).
#
# The mod compile step fails if the script compiler reports any warning located in this
# mod's own source. Warnings from the SDK's base-game packages (missing content on the
# default SDK branch) are still printed but do not fail the build.

class StrictMakeReceiver : MakeStdoutReceiver {
	[string[]] $ownSourceMarkers
	# The compiler prints each warning inline and again in its summary
	[System.Collections.Generic.HashSet[string]] $ownWarnings

	StrictMakeReceiver([BuildProject]$proj) : base($proj) {
		$this.ownWarnings = New-Object System.Collections.Generic.HashSet[string]
		$this.ownSourceMarkers = @($proj.modScriptPackages | ForEach-Object { "\Src\$(Split-Path $_ -Leaf)\" })
	}

	[void]ParseLine([string] $outTxt) {
		([MakeStdoutReceiver]$this).ParseLine($outTxt)

		if ($outTxt -notmatch ' : Warning,') {
			return
		}

		foreach ($marker in $this.ownSourceMarkers) {
			if ($outTxt.IndexOf($marker, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
				[void]$this.ownWarnings.Add($outTxt.Trim())
				return
			}
		}
	}

	[void]Finish([int] $exitCode) {
		([MakeStdoutReceiver]$this).Finish($exitCode)

		if ($this.ownWarnings.Count -gt 0) {
			ThrowFailure "$($this.ownWarnings.Count) compiler warning(s) in mod source; the build must be warning-free"
		}
	}
}

class StrictBuildProject : BuildProject {
	StrictBuildProject([string]$mod, [string]$projectRoot, [string]$sdkPath, [string]$gamePath) : base($mod, $projectRoot, $sdkPath, $gamePath) {
	}

	[void]_RunMakeMod() {
		$scriptsMakeArguments = "make -nopause -mods $($this.modNameCanonical) $($this.stagingPath)"
		if ($this.debug -eq $true) {
			$scriptsMakeArguments = "$scriptsMakeArguments -debug"
		}
		$handler = [StrictMakeReceiver]::new($this)
		$handler.processDescr = "compiling mod scripts"
		$this._InvokeEditorCmdlet($handler, $scriptsMakeArguments, 50)
	}
}
