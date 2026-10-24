#Requires -Version 7.2
<#
.SYNOPSIS
    Enroll a YubiKey PIV certificate from the step-ca client CA ON BEHALF of a user: key generated ON the card, cert
    approved by the admin with a one-time token (OTT). Also used for renewal (re-enrollment) and store cleanup.

.DESCRIPTION
    Flow: the ADMIN runs this script with the user's YubiKey (initial PIN known to the admin), enrolls, and only
    AFTER the enrollment the user's own PIN is configured. A "change PIN on first use" requirement must be switched on
    after this script, never before - otherwise it can block certreq -new / -accept.

      certreq -new (minidriver, key on the card) -> step ca token + step ca sign -> certreq -accept
      -> fingerprint search over all slots -> superseded certs and stale store copies -> PIN handover.

    The OTT replaces the Enrollment Agent signature of an AD CS on-behalf-of enrollment: 'step ca token' fetches the
    encrypted key of the JWK provisioner from the CA over HTTPS and decrypts it locally with the provisioner password
    (masked prompt of step). Whoever knows that password can issue for ANY user of the name policy - treat it like an
    Enrollment Agent certificate. The token is for exactly one UPN, valid ~5 minutes, usable once, and only lives in
    a variable. -TokenFile is the alternative when the token was created on another machine.

    Renewal: the provisioner has renewal disabled (a stolen certificate cannot extend itself), so a certificate is
    renewed by running this script again before it expires: new key, new certificate, then the old one is revoked.
    -RenewWithinDays marks certificates of this CA on the card that expire within that many days.

    Modes:
      (default)      enrollment / re-enrollment
      -CheckOnly     preconditions, card inventory (with expiry) and store check - touches neither card nor CA
      -CleanupStore  remove CurrentUser\My copies of revoked or expired client certs that are no longer on the card
                     (certificate propagation never removes them; the browser picker keeps offering them).
                     Public cert exported first, the card is not touched. Confirms per cert.

    Built-in lessons:
      * certreq -accept needs the full chain and reads only the FIRST cert of the PEM bundle -> the client root
        must be trusted and the issuing CA must be in CurrentUser\CA beforehand (imported here if missing).
      * RDP also redirects the Windows Hello for Business virtual smart card -> pick the YubiKey in the dialog.
      * The minidriver picks the container; with 9a occupied the key lands in another slot. The slot is found by
        fingerprint afterwards.
      * Revocation order: test the new cert, revoke the old one, refresh the CRL on the NetScaler, negative test,
        THEN delete the old cert from the card and run -CleanupStore. The script prints the commands, it does not revoke.

.PARAMETER ConfigFile
    JSON like config/example.json, "clientCa" section (and "gatewayUrl" for the test hint).

.PARAMETER Upn
    UPN of the certificate holder (CN, SAN email, and the UPN otherName added by the CA template). Without it an
    AD user picker (RSAT) or a prompt is shown.

.PARAMETER TokenFile
    Use a token created elsewhere (file is read and deleted at once) instead of running 'step ca token' here.

.EXAMPLE
    ./scripts/Enroll-YubiKeyPiv.ps1 -ConfigFile ./config/lab.local.json -CheckOnly

.EXAMPLE
    ./scripts/Enroll-YubiKeyPiv.ps1 -ConfigFile ./config/lab.local.json -Upn user1@example.org

.NOTES
    Requires: step CLI with a bootstrapped context (docs/client-ca.md), ykman, YubiKey Minidriver.
    Run it in Windows Terminal: the classic console prints the ANSI sequences of step as text, so step's masked
    password prompt shows one new line per keystroke (cosmetic, the password is not shown).
    Secrets: the provisioner password and the PIN are only typed into the prompts of step / Windows; the script
    never sees them. The OTT lives in a variable until 'step ca sign' has used it.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)] [string] $ConfigFile,
    [string]$Upn,
    [string]$TokenFile,
    [int]$RenewWithinDays = -1,
    [string]$ProviderName = 'Microsoft Base Smart Card Crypto Provider',
    [string]$WorkDir = "$HOME\pki-offline\enroll",
    [switch]$CheckOnly,
    [switch]$CleanupStore
)

$ErrorActionPreference = 'Stop'
$cfg = Get-Content -Raw -LiteralPath $ConfigFile | ConvertFrom-Json
$ca  = $cfg.clientCa
if (-not $ca) { throw "clientCa section missing in $ConfigFile" }
foreach ($k in 'stepContext', 'rootFingerprint', 'issuerName', 'crlUrl', 'provisioner') {
    if (-not $ca.$k -or "$($ca.$k)" -match '^<') { throw "clientCa.$k missing or placeholder in $ConfigFile" }
}
$StepContext     = $ca.stepContext
$RootFingerprint = $ca.rootFingerprint.ToLower()
$IssuerName      = $ca.issuerName
$CrlUrl          = $ca.crlUrl
$Provisioner     = $ca.provisioner
$NsCrlName       = $ca.netscalerCrlName ?? 'crl_client_issuing'
if ($RenewWithinDays -lt 0) { $RenewWithinDays = [int]($ca.renewWithinDays ?? 21) }

function Assert-Success {
    param([string]$Step)
    if ($LASTEXITCODE -ne 0) { throw "Step '$Step' failed with exit code $LASTEXITCODE. Aborting." }
}

function Get-Sha256Hex {
    param([System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert)
    -join ([System.Security.Cryptography.SHA256]::HashData($Cert.RawData) | ForEach-Object { $_.ToString('x2') })
}

function Get-YkmanPivInfo {
    $infoText = (& ykman piv info 2>$null) -join "`n"
    if (-not $infoText) { throw "Could not read PIV info via ykman - is exactly one YubiKey inserted (RDP smart card redirection), and is Yubico Authenticator closed (it holds the card)?" }
    return $infoText
}

function Get-PivSlotCertificates {
    # Every populated slot (9a/9c/9d/9e and retired 82-95) from 'ykman piv info'.
    param([Parameter(Mandatory)][string]$InfoText)
    $slotMatches = [regex]::Matches($InfoText, "Slot (\S+) \(([^)]+)\):.*?(?=\r?\nSlot |\z)", 'Singleline')
    foreach ($m in $slotMatches) {
        $subject     = [regex]::Match($m.Value, "Subject DN:\s*(.+)")
        $issuer      = [regex]::Match($m.Value, "Issuer DN:\s*(.+)")
        $serial      = [regex]::Match($m.Value, "Serial:\s*(\S+)")
        $fingerprint = [regex]::Match($m.Value, "Fingerprint:\s*(\S+)")
        $notAfter    = [regex]::Match($m.Value, "Not after:\s*(.+)")
        if ($subject.Success) {
            $na = [datetime]::MinValue
            $hasNa = $notAfter.Success -and [datetime]::TryParse($notAfter.Groups[1].Value.Trim(), [ref]$na)
            [PSCustomObject]@{
                Slot        = $m.Groups[1].Value
                SlotName    = $m.Groups[2].Value
                Subject     = $subject.Groups[1].Value.Trim()
                Issuer      = if ($issuer.Success) { $issuer.Groups[1].Value.Trim() } else { '' }
                SerialHex   = if ($serial.Success) { ($serial.Groups[1].Value -replace ':', '').TrimStart('0').ToUpper() } else { '' }
                Fingerprint = if ($fingerprint.Success) { $fingerprint.Groups[1].Value } else { '<unknown>' }
                NotAfter    = if ($hasNa) { $na } else { $null }
                DaysLeft    = if ($hasNa) { [int][math]::Floor(($na - (Get-Date)).TotalDays) } else { $null }
            }
        }
    }
}

function ConvertTo-DecimalSerial {
    # step ca revoke takes the serial in decimal.
    param([string]$Hex)
    [System.Numerics.BigInteger]::Parse("00$Hex", 'AllowHexSpecifier').ToString()
}

function Get-TargetUpn {
    if (Get-Module -ListAvailable -Name ActiveDirectory) {
        Import-Module ActiveDirectory -ErrorAction SilentlyContinue
        $picked = Get-ADUser -Filter 'UserPrincipalName -like "*"' -Properties UserPrincipalName |
            Select-Object Name, SamAccountName, UserPrincipalName |
            Out-GridView -Title 'Select the user to enroll a certificate for' -OutputMode Single
        if ($picked) { return $picked.UserPrincipalName }
    }
    $u = Read-Host 'Enter the UPN of the certificate holder (e.g. user1@example.org)'
    if (-not $u) { throw 'No UPN given. Aborting.' }
    return $u
}

function Test-InStore {
    param([string]$Thumbprint, [string[]]$Stores)
    foreach ($s in $Stores) { if (Test-Path "Cert:\$s\$Thumbprint") { return $true } }
    return $false
}

function Get-ClientStoreCerts {
    Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Issuer -eq "CN=$IssuerName" }
}

function Get-RevokedSerials {
    # Fresh CRL via step (signature checked against the issuing CA), not the Windows CRL cache - a cached CRL
    # stays "valid" until its NextUpdate and would miss a revocation from minutes ago. Decimal serials, or $null.
    $issuing = Get-ChildItem Cert:\CurrentUser\CA, Cert:\LocalMachine\CA | Where-Object Subject -eq "CN=$IssuerName" | Select-Object -First 1
    if (-not $issuing) { return $null }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "issuing-$($issuing.Thumbprint).crt"
    "-----BEGIN CERTIFICATE-----`n$([Convert]::ToBase64String($issuing.RawData, 'InsertLineBreaks'))`n-----END CERTIFICATE-----" | Set-Content $tmp -Encoding ascii
    try {
        $json = (& step crl inspect --format json --ca $tmp $CrlUrl 2>$null) -join "`n"
        if ($LASTEXITCODE -ne 0 -or -not $json) { return $null }
        return @(($json | ConvertFrom-Json).revoked_certificates.serial_number)
    }
    catch { return $null }
    finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
}

function Show-StoreState {
    # A store copy is STALE only if its cert is revoked or expired. A valid cert that is just not on the inserted
    # card is probably on another YubiKey of the same user - it is kept (cert propagation would re-add it anyway).
    param([string[]]$CardFingerprints)
    $storeCerts = @(Get-ClientStoreCerts)
    if (-not $storeCerts) { Write-Host 'CurrentUser\My: no certificates from this CA.' -ForegroundColor DarkGray; return @() }
    $revoked = Get-RevokedSerials
    if ($null -eq $revoked) { Write-Warning "CRL $CrlUrl not readable - revocation state unknown, nothing counts as stale." }
    $stale = foreach ($c in $storeCerts) {
        $onCard = $CardFingerprints -contains (Get-Sha256Hex $c)
        $state  = if ($c.NotAfter -lt (Get-Date)) { 'expired' }
                  elseif ($null -eq $revoked) { 'unknown' }
                  elseif ($revoked -contains (ConvertTo-DecimalSerial $c.SerialNumber)) { 'revoked' }
                  else { 'valid' }
        $isStale = $state -in 'revoked', 'expired'
        $flag = if ($onCard) { "on card, $state" }
                elseif ($isStale) { "NOT on card, $state -> stale copy" }
                else { "not on this card, $state (another YubiKey?) - kept" }
        $color = if ($isStale) { 'Yellow' } elseif ($onCard) { 'DarkGray' } else { 'Cyan' }
        Write-Host ("CurrentUser\My {0}  serial {1}  until {2:yyyy-MM-dd}  {3}  {4}" -f $c.Thumbprint, $c.SerialNumber, $c.NotAfter, $c.Subject, $flag) -ForegroundColor $color
        if ($isStale -and -not $onCard) { $c }
    }
    return @($stale)
}

# ---- Preconditions ----

foreach ($cmd in 'certreq', 'step', 'ykman') {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { throw "'$cmd' not found on PATH." }
}

$health = (& step ca health --context $StepContext 2>&1) -join ' '
if ($health -notmatch '\bok\b') { throw "step ca health --context $StepContext failed: $health (docs/client-ca.md, workstation bootstrap)" }
Write-Host "step-ca ($StepContext): ok" -ForegroundColor Green

$rootFile = "$HOME\.step\authorities\$StepContext\certs\root_ca.crt"
if (-not (Test-Path $rootFile)) { throw "Root not found: $rootFile (run 'step ca bootstrap', docs/client-ca.md)." }
$rootFp = (& step certificate fingerprint $rootFile).Trim()
if ($rootFp -ne $RootFingerprint) { throw "Root fingerprint mismatch: $rootFp, expected $RootFingerprint." }
$rootCert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($rootFile)
$rootTrusted = Test-InStore $rootCert.Thumbprint 'CurrentUser\Root', 'LocalMachine\Root'
Write-Host ("Client root {0}: {1}" -f $rootCert.Subject, $(if ($rootTrusted) { 'trusted' } else { 'NOT trusted' })) -ForegroundColor $(if ($rootTrusted) { 'Green' } else { 'Yellow' })

$infoText = Get-YkmanPivInfo
$pinTries = [regex]::Match($infoText, 'PIN tries remaining:\s*(\d+)').Groups[1].Value
$pukBlocked = $infoText -match 'PUK is blocked'
$defaultPin = $infoText -match 'Using default PIN'   # reported from fw 5.3 on (PIN metadata)
Write-Host "`n=== YubiKey ===" -ForegroundColor Yellow
Write-Host ("PIN tries remaining: {0}{1}" -f $pinTries, $(if ($pukBlocked) { '  (PUK blocked: a locked PIN means a full PIV reset)' } else { '' }))
if ($defaultPin) { Write-Host 'Default PIN (123456) is still set - fine for the enrollment, change it at the handover.' -ForegroundColor Yellow }
$cardCerts = @(Get-PivSlotCertificates -InfoText $infoText)
if ($cardCerts) {
    foreach ($c in $cardCerts) {
        $ours  = $c.Issuer -eq "CN=$IssuerName"
        $renew = $ours -and $null -ne $c.DaysLeft -and $c.DaysLeft -le $RenewWithinDays
        $until = if ($c.NotAfter) { '{0:yyyy-MM-dd} ({1} days)' -f $c.NotAfter, $c.DaysLeft } else { '?' }
        $flag  = if (-not $ours) { '  (other CA)' } elseif ($c.DaysLeft -lt 0) { '  <-- EXPIRED, re-enroll' } elseif ($renew) { "  <-- renew (within $RenewWithinDays days)" } else { '' }
        Write-Host ("Slot {0} ({1}): {2}  serial {3}  until {4}{5}" -f $c.Slot, $c.SlotName, $c.Subject, $c.SerialHex, $until, $flag) -ForegroundColor $(if ($renew) { 'Yellow' } else { 'Gray' })
    }
} else {
    Write-Host 'No certificates on the card.' -ForegroundColor DarkGray
}

Write-Host "`n=== Windows store ===" -ForegroundColor Yellow
$stale = Show-StoreState -CardFingerprints $cardCerts.Fingerprint

if ($CleanupStore) {
    if (-not $stale) { Write-Host 'Nothing to clean up.' -ForegroundColor Green; return }
    New-Item -ItemType Directory -Force $WorkDir | Out-Null
    foreach ($c in $stale) {
        if ($PSCmdlet.ShouldProcess("$($c.Subject) serial $($c.SerialNumber) ($($c.Thumbprint))", 'Remove stale copy from CurrentUser\My')) {
            $backup = Join-Path $WorkDir ("stale-{0}.cer" -f $c.SerialNumber)
            Export-Certificate -Cert $c -FilePath $backup -Type CERT | Out-Null
            Remove-Item "Cert:\CurrentUser\My\$($c.Thumbprint)"   # no -DeleteKey: the card is not touched
            Write-Host "Removed $($c.Thumbprint), backup $backup" -ForegroundColor Green
        }
    }
    return
}

if ($CheckOnly) { Write-Host "`nCheck only - nothing changed." -ForegroundColor DarkGray; return }

# ---- Enrollment ----

if (-not $Upn) { $Upn = Get-TargetUpn }
$short = $Upn.Split('@')[0]

if ([int]$pinTries -lt 3) {
    $answer = Read-Host "Only $pinTries PIN tries left. Continue anyway? (yes/no)"
    if ($answer -ne 'yes') { throw 'Aborted by user.' }
}

if (-not $rootTrusted) {
    Write-Host "`nThe client root must be trusted, otherwise 'certreq -accept' fails with CERT_E_CHAINING." -ForegroundColor Yellow
    $answer = Read-Host "Import '$($rootCert.Subject)' (SHA-256 $rootFp) into CurrentUser\Root? Windows asks to confirm. (yes/no)"
    if ($answer -ne 'yes') { throw 'Client root not trusted. Aborting.' }
    Import-Certificate -FilePath $rootFile -CertStoreLocation Cert:\CurrentUser\Root | Out-Null
    if (-not (Test-InStore $rootCert.Thumbprint 'CurrentUser\Root')) { throw 'Root import was not confirmed. Aborting.' }
}

New-Item -ItemType Directory -Force $WorkDir | Out-Null
$stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$infPath = Join-Path $WorkDir "$short`_$stamp.inf"
$csrPath = Join-Path $WorkDir "$short`_$stamp.csr"
$pemPath = Join-Path $WorkDir "$short`_$stamp.req.pem"
$crtPath = Join-Path $WorkDir "$short`_$stamp.crt"

# Written line by line: a here-string pasted into a console breaks.
@(
    '[Version]'
    'Signature = "$Windows NT$"'
    ''
    '[NewRequest]'
    "Subject = ""CN=$Upn"""
    'KeySpec = 1'
    'KeyLength = 2048'
    'KeyUsage = 0x80'
    "ProviderName = ""$ProviderName"""
    'ProviderType = 1'
    'RequestType = PKCS10'
    'Exportable = FALSE'
    ''
    '[Extensions]'
    '2.5.29.17 = "{text}"'
    "_continue_ = ""email=$Upn"""
) | Set-Content -Path $infPath -Encoding ascii

Write-Host "`n=== Step 1/4: key + request on the YubiKey ===" -ForegroundColor Yellow
Write-Host 'If Windows asks for a smart card: choose the YubiKey, NOT "Windows Hello for Business".'
Write-Host "PIN: the card's INITIAL PIN (the user's own PIN is set after the enrollment). $pinTries tries left - if unsure, cancel instead of guessing."
Read-Host "Insert the YubiKey of $Upn, then press Enter"
certreq -new $infPath $csrPath
Assert-Success 'certreq -new'
(Get-Content $csrPath -Raw) -replace 'NEW CERTIFICATE REQUEST', 'CERTIFICATE REQUEST' | Set-Content $pemPath -Encoding ascii

Write-Host "`n=== Step 2/4: admin approval - one-time token for $Upn ===" -ForegroundColor Yellow
if ($TokenFile) {
    if (-not (Test-Path $TokenFile)) { throw "Token file not found: $TokenFile" }
    $age = (Get-Date) - (Get-Item $TokenFile).LastWriteTime
    if ($age.TotalMinutes -gt 5) { Write-Warning ("Token file is {0:N0} minutes old - the token has probably expired." -f $age.TotalMinutes) }
    $token = (Get-Content $TokenFile -Raw).Trim()
    Remove-Item $TokenFile
}
else {
    Write-Host "step asks for the password of the provisioner $Provisioner (masked)."
    $token = ((& step ca token $Upn --provisioner $Provisioner --context $StepContext) -join '').Trim()
    Assert-Success 'step ca token'
}
if ($token -notmatch '^[\w-]+\.[\w-]+\.[\w-]+$') { Remove-Variable token; throw 'No valid token received. Aborting.' }

Write-Host "`n=== Step 3/4: sign at step-ca ===" -ForegroundColor Yellow
try {
    step ca sign $pemPath $crtPath --context $StepContext --token $token
    Assert-Success 'step ca sign'
}
finally {
    Remove-Variable token -ErrorAction SilentlyContinue
}

$blocks = [regex]::Matches((Get-Content $crtPath -Raw), '-----BEGIN CERTIFICATE-----[\s\S]+?-----END CERTIFICATE-----') | ForEach-Object Value
if ($blocks.Count -lt 2) { throw "Expected leaf + issuing CA in $crtPath, found $($blocks.Count) certificate(s)." }
$leaf    = [System.Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem($blocks[0])
$issuing = [System.Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem($blocks[1])

$san = ($leaf.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' }).Format($false)
$eku = ($leaf.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.37' }).Format($false)
$cdp = ($leaf.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.31' }).Format($false)
if ($san -notmatch "Principal Name=$([regex]::Escape($Upn))") { throw "Issued cert has no UPN otherName for $Upn (SAN: $san)." }
if ($eku -notmatch '1\.3\.6\.1\.5\.5\.7\.3\.2') { throw "Issued cert lacks EKU Client Authentication ($eku)." }
if ($cdp -notmatch [regex]::Escape($CrlUrl)) { Write-Warning "Issued cert CDP ($cdp) does not contain $CrlUrl - check the CA template." }
$csrKey  = (& step certificate key $pemPath) -join "`n"
$certKey = (& step certificate key $crtPath) -join "`n"
if ($csrKey -ne $certKey) { throw 'Public key of the issued cert does not match the CSR.' }
Write-Host ("Issued: serial {0}, until {1:yyyy-MM-dd}, SAN {2}" -f $leaf.SerialNumber, $leaf.NotAfter, $san) -ForegroundColor Green

if (-not (Test-InStore $issuing.Thumbprint 'CurrentUser\CA', 'LocalMachine\CA')) {
    $issuingPath = Join-Path $WorkDir 'issuing_ca.crt'
    $blocks[1] | Set-Content $issuingPath -Encoding ascii
    Import-Certificate -FilePath $issuingPath -CertStoreLocation Cert:\CurrentUser\CA | Out-Null
    Write-Host "Imported $($issuing.Subject) into CurrentUser\CA (certreq -accept reads only the first PEM block)." -ForegroundColor DarkGray
}

Write-Host "`n=== Step 4/4: certificate onto the YubiKey ===" -ForegroundColor Yellow
Read-Host "Confirm the YubiKey of $Upn is still inserted, then press Enter"
certreq -accept $crtPath
Assert-Success 'certreq -accept'

# ---- Verification ----

Write-Host "`n=== Verification ===" -ForegroundColor Yellow
$issuedFp  = Get-Sha256Hex $leaf
$cardCerts = @(Get-PivSlotCertificates -InfoText (Get-YkmanPivInfo))
$landed    = $cardCerts | Where-Object Fingerprint -eq $issuedFp | Select-Object -First 1
if (-not $landed) {
    Write-Host "The issued certificate (SHA-256 $issuedFp) is in NO slot. Same YubiKey? Did certreq -accept succeed?" -ForegroundColor Red
    throw 'Issued certificate not found on the card.'
}
Write-Host "Slot $($landed.Slot) ($($landed.SlotName)) holds the new certificate for $($landed.Subject)." -ForegroundColor Green

$others = @($cardCerts | Where-Object Slot -ne $landed.Slot)
foreach ($c in $others) {
    $sameUser = $c.Subject -eq "CN=$Upn"
    $color = if ($sameUser) { 'Yellow' } else { 'Red' }
    $flag  = if ($sameUser) { 'superseded (same UPN)' } else { 'different identity' }
    Write-Host ("Slot {0} ({1}): {2}  serial {3}  <-- {4}" -f $c.Slot, $c.SlotName, $c.Subject, $c.SerialHex, $flag) -ForegroundColor $color
}

Write-Host "`n=== Windows store ===" -ForegroundColor Yellow
Show-StoreState -CardFingerprints $cardCerts.Fingerprint | Out-Null

$superseded = @($others | Where-Object { $_.Subject -eq "CN=$Upn" -and $_.Issuer -eq "CN=$IssuerName" })
$testUrl = if ($cfg.gatewayUrl) { $cfg.gatewayUrl } else { 'the mTLS Gateway URL' }
Write-Host "`n=== Next (in this order) ===" -ForegroundColor Yellow
Write-Host ("1. Test: replug, browser -> {0}, pick the NEW cert: valid from {1:yyyy-MM-dd HH:mm}, serial {2}" -f $testUrl, $leaf.NotBefore, $leaf.SerialNumber)
Write-Host '   (expiry dates can be identical - the picker''s "valid from" / certificate details tell them apart).'
if ($superseded) {
    Write-Host '2. Admin - revoke the superseded cert(s) (provisioner password prompt, works from here over HTTPS):'
    foreach ($c in $superseded) {
        Write-Host "     step ca revoke $(ConvertTo-DecimalSerial $c.SerialHex) --context $StepContext --reason `"superseded`"   # serial $($c.SerialHex), slot $($c.Slot)" -ForegroundColor Cyan
    }
    Write-Host '   NetScaler CLI (">" prompt - NOT the shell, where "set" silently does nothing), fetch the new CRL now:'
    Write-Host "     set ssl crl $NsCrlName -interval NOW ; show ssl crl $NsCrlName   # serial must be listed" -ForegroundColor Cyan
    Write-Host '   Until then the Gateway still accepts the old cert.'
    Write-Host '3. Negative test: new private window, pick the OLD cert -> must fail (connection reset).'
    Write-Host ('4. Card: ' + (($superseded | ForEach-Object { "ykman piv certificates delete $($_.Slot)" }) -join ' ; '))
    Write-Host "5. Store, on every PC the card was used on: .\Enroll-YubiKeyPiv.ps1 -ConfigFile <config> -CleanupStore"
} else {
    Write-Host '2. No superseded certificate of this UPN on the card.'
}

Write-Host "`n=== Handover: user PIN - AFTER the enrollment, never before ===" -ForegroundColor Yellow
Write-Host '1. The user sets their own PIN, replacing the initial PIN, e.g.:'
Write-Host '     ykman piv access change-pin        # masked prompts, old + new PIN' -ForegroundColor Cyan
Write-Host '   or Windows: Ctrl+Alt+Del (RDP: Ctrl+Alt+End) -> Change a password -> the smart card.'
Write-Host '2. Only now switch on a "change PIN on first use" requirement, if used - set before the enrollment it can'
Write-Host '   block certreq -new / -accept.'
$cardNow = (& ykman piv info 2>$null) -join "`n"
if ($cardNow -match 'Using default PIN') {
    Write-Host '   The card still has the DEFAULT PIN 123456 - the PIN change is mandatory before the card is handed over.' -ForegroundColor Yellow
}
if ($cardNow -match 'PUK is blocked') {
    Write-Host '3. PUK is blocked (on a freshly reset card the Yubico minidriver does this itself during the enrollment, together'
    Write-Host '   with a random PIN-protected management key): 3 wrong PINs lock the card for good -> PIV reset + re-enrollment.' -ForegroundColor Yellow
}
Write-Host "`nWorking files kept in $WorkDir." -ForegroundColor DarkGray
