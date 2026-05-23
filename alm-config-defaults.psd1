@{
    scriptDependencies = @{
        "Rnwood.Dataverse.Data.PowerShell" = "3.0.3"
    }

    # Power Apps CLI version used by pipeline scripts.
    # Supports: '' (latest stable), 'prerelease', or an exact version.
    pacCliVersion = '2.7.4'

    # Timeout in seconds for each solution import operation.
    # Increase this value if solution imports time out in large or complex environments.
    importTimeoutSeconds = 10800
}
