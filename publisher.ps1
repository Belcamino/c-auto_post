# publisher.ps1
# Daemon di pubblicazione automatica per Facebook e Instagram.
# Gira in loop continuo: ogni ora rilegge plan.md e immagini.md e pubblica
# i post schedulati, aggiornando lo status da "pending" a "published".
#
# Posizionarsi nella directory del progetto prima di eseguire:
#   cd C:\Users\belcami1\OneDrive\Documenti\CODING\CLAUDE\c-auto_post
#   .\publisher.ps1
#
# Opzioni:
#   -Debug               Mostra dettagli del parsing a video e nel log
#   -DryRun              Non pubblica, mostra solo cosa farebbe
#   -GitStart            Crea repo locale, fa add + commit iniziale ed esce
#   -GitPush             Esegue git push su GitHub ed esce
#   -IntervalMinutes N   Intervallo tra cicli (default: 60)
#   -ToleranceMinutes N  Finestra di tolleranza post-orario (default: 30)
#   -MaxLogSizeMB N      Dimensione massima log prima della rotazione (default: 5)
#
# Per fermare lo script: Ctrl+C

param (
    [int]$IntervalMinutes  = 60,
    [int]$ToleranceMinutes = 30,
    [int]$MaxLogSizeMB     = 5,
    [switch]$DryRun,
    [switch]$GitStart,
    [switch]$GitPush,
    [switch]$Debug
)

# ─────────────────────────────────────────────────────────────
# CONFIGURAZIONE PERCORSI
# ─────────────────────────────────────────────────────────────
$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$EnvFile      = Join-Path $ScriptDir ".env"
$PlanFile     = Join-Path $ScriptDir "plan.md"
$FbScript     = Join-Path $ScriptDir "fb_publisher.py"
$IgScript     = Join-Path $ScriptDir "ig_publisher.py"
$LogFile      = Join-Path $ScriptDir "publisher.log"

# ─────────────────────────────────────────────────────────────
# FUNZIONE: Rotazione del log
# ─────────────────────────────────────────────────────────────
function Rotate-Log {
    param([string]$LogPath, [int]$MaxSizeMB, [int]$MaxFiles = 3)
    if (-not (Test-Path $LogPath)) { return }
    $sizeMB = (Get-Item $LogPath).Length / 1MB
    if ($sizeMB -lt $MaxSizeMB) { return }

    for ($i = $MaxFiles - 1; $i -ge 1; $i--) {
        $src = "$LogPath.$i"
        $dst = "$LogPath.$($i + 1)"
        if (Test-Path $src) {
            if ($i -eq ($MaxFiles - 1)) { Remove-Item $src -Force }
            else { Rename-Item $src $dst -Force }
        }
    }
    Rename-Item $LogPath "$LogPath.1" -Force
    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') Log ruotato ($([math]::Round($sizeMB,1)) MB)" -ForegroundColor DarkGray
}

# ─────────────────────────────────────────────────────────────
# FUNZIONE: Scrive nel log e a schermo
# ─────────────────────────────────────────────────────────────
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    switch ($Level) {
        "INFO"    { Write-Host $line -ForegroundColor Cyan }
        "SUCCESS" { Write-Host $line -ForegroundColor Green }
        "WARN"    { Write-Host $line -ForegroundColor Yellow }
        "ERROR"   { Write-Host $line -ForegroundColor Red }
        "DEBUG"   { Write-Host $line -ForegroundColor Magenta }
        default   { Write-Host $line }
    }
}

function Write-Debug-Msg {
    param([string]$Message)
    if ($script:Debug) { Write-Log $Message "DEBUG" }
}

# ─────────────────────────────────────────────────────────────
# FUNZIONE: Carica le variabili d'ambiente dal file .env
# ─────────────────────────────────────────────────────────────
function Import-EnvFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        Write-Log "File .env non trovato: $Path" "ERROR"
        exit 1
    }
    Get-Content $Path | Where-Object { $_ -match '=' -and $_ -notmatch '^\s*#' } | ForEach-Object {
        $parts = $_.Split('=', 2)
        $key   = $parts[0].Trim()
        $value = $parts[1].Trim().Trim('"')
        Set-Item "env:$key" $value
    }
    Write-Log "Variabili d'ambiente caricate da .env"
}

# ─────────────────────────────────────────────────────────────
# FUNZIONE: Analizza plan.md ed estrae i post da pubblicare
# ─────────────────────────────────────────────────────────────
function Read-PendingPosts {
    param([string]$Path, [datetime]$Now, [int]$ToleranceMinutes)

    $posts       = @()
    $lines       = Get-Content $Path -Encoding UTF8
    $n           = $lines.Count
    $currentDate = $null
    $i           = 0

    Write-Debug-Msg "Read-PendingPosts: $n righe totali, Now=$($Now.ToString('yyyy-MM-dd HH:mm')), Tolerance=${ToleranceMinutes}min"

    while ($i -lt $n) {
        $line = $lines[$i]

        # Rileva data: ## 2026-04-27
        if ($line -match '^##\s+(\d{4}-\d{2}-\d{2})\s*$') {
            $currentDate = $Matches[1]
            Write-Debug-Msg "  riga $($i+1): data rilevata -> $currentDate"
            $i++
            continue
        }

        # Rileva intestazione post: ### 🔵 Facebook — HH:mm  oppure  ### 📸 Instagram — HH:mm
        if ($line -match '(?i)^###\s+[^\r\n]*(Facebook|Instagram)[^\r\n]*\s(\d{2}:\d{2})\s*$') {
            $postType = $Matches[1]
            $postTime = $Matches[2]
            Write-Debug-Msg "  riga $($i+1): header '$postType $postTime' (data corrente: $currentDate)"

            if (-not $currentDate) {
                Write-Debug-Msg "    SKIP: nessuna data corrente"
                $i++
                continue
            }

            # Raccoglie il blocco fino al prossimo ### o ##
            $blockStart = $i + 1
            $blockEnd   = $blockStart
            while ($blockEnd -lt $n -and $lines[$blockEnd] -notmatch '^#{2,3}\s') {
                $blockEnd++
            }
            $blockLines = if ($blockStart -lt $blockEnd) { $lines[$blockStart..($blockEnd - 1)] } else { @() }

            Write-Debug-Msg "    blocco: righe $($blockStart+1)..$blockEnd ($($blockLines.Count) righe)"

            if ($script:Debug) {
                foreach ($bl in $blockLines) {
                    Write-Debug-Msg "      | $bl"
                }
            }

            # Cerca **Status:** ⏳ pending
            $statusLineIndex = -1
            for ($j = 0; $j -lt $blockLines.Count; $j++) {
                if ($blockLines[$j] -match '\*\*Status:\*\*[^\r\n]*pending') {
                    $statusLineIndex = $blockStart + $j
                    Write-Debug-Msg "    status pending trovato a riga file $($statusLineIndex+1)"
                    break
                }
            }

            if ($statusLineIndex -lt 0) {
                Write-Debug-Msg "    SKIP: nessuno status pending trovato"
                $i = $blockEnd
                continue
            }

            # Costruisce il datetime schedulato
            try {
                $scheduledDt = [datetime]::ParseExact(
                    "$currentDate $postTime", "yyyy-MM-dd HH:mm", $null
                )
            } catch {
                Write-Log "Data non valida: $currentDate $postTime" "WARN"
                $i = $blockEnd
                continue
            }

            $deadline = $Now.AddMinutes($ToleranceMinutes)
            Write-Debug-Msg "    scheduled=$($scheduledDt.ToString('yyyy-MM-dd HH:mm')), deadline=$($deadline.ToString('yyyy-MM-dd HH:mm')), ok=$($scheduledDt -le $deadline)"

            if ($scheduledDt -le $deadline) {
                # Estrae testo e image URL dal blocco
                $textLines = @()
                $imageUrl  = $null
                $inText    = $false

                foreach ($bl in $blockLines) {
                    if ($bl -match '^\*\*Image:\*\*\s*(https?://\S+)') {
                        $imageUrl = $Matches[1]
                        Write-Debug-Msg "    imageUrl: $imageUrl"
                        continue
                    }
                    if ($bl -match '^\*\*(Topic|Status|Image note):\*\*') { continue }
                    if ($bl -match '^---\s*$') { break }
                    if (-not $inText -and [string]::IsNullOrWhiteSpace($bl)) { continue }
                    $inText = $true
                    $textLines += $bl
                }

                # Rimuove righe vuote finali
                while ($textLines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($textLines[-1])) {
                    $textLines = $textLines[0..($textLines.Count - 2)]
                }

                $postText = ($textLines -join "`n").Trim()
                Write-Debug-Msg "    testo estratto ($($postText.Length) chars): $($postText.Substring(0, [Math]::Min(60, $postText.Length)))..."

                $posts += [PSCustomObject]@{
                    Date            = $currentDate
                    Time            = $postTime
                    Type            = $postType
                    Text            = $postText
                    ImageUrl        = $imageUrl
                    StatusLineIndex = $statusLineIndex
                    Scheduled       = $scheduledDt
                }
            }

            $i = $blockEnd
            continue
        }

        $i++
    }

    Write-Debug-Msg "Read-PendingPosts completato: $($posts.Count) post da pubblicare"
    return $posts
}

# ─────────────────────────────────────────────────────────────
# FUNZIONE: Aggiorna lo status di un post in plan.md
# ─────────────────────────────────────────────────────────────
function Update-PostStatus {
    param([string]$Path, [int]$LineIndex, [string]$NewStatus)
    $lines = Get-Content $Path -Encoding UTF8
    $lines[$LineIndex] = "**Status:** $NewStatus"
    Set-Content -Path $Path -Value $lines -Encoding UTF8
}

# ─────────────────────────────────────────────────────────────
# FUNZIONE: Rimuove la sintassi Markdown dal testo
# ─────────────────────────────────────────────────────────────
function Remove-Markdown {
    param([string]$Text)
    $Text = $Text -replace '\*\*(.+?)\*\*', '$1'   # bold
    $Text = $Text -replace '\*(.+?)\*',     '$1'   # italic
    return $Text
}

# ─────────────────────────────────────────────────────────────
# FUNZIONE: Pubblica un singolo post
# Testo e immagine vengono passati via variabili d'ambiente
# per evitare troncamenti da quoting della riga di comando.
# ─────────────────────────────────────────────────────────────
function Publish-Post {
    param([PSCustomObject]$Post)

    $label = "$($Post.Type) [$($Post.Date) $($Post.Time)]"
    $cleanText = Remove-Markdown $Post.Text

    if ($DryRun) {
        Write-Log "[DRY-RUN] Pubblicherebbe: $label" "WARN"
        Write-Log "[DRY-RUN] Testo: $($cleanText.Substring(0, [Math]::Min(80, $cleanText.Length)))..." "WARN"
        if ($Post.ImageUrl) { Write-Log "[DRY-RUN] Immagine: $($Post.ImageUrl)" "WARN" }
        return $true
    }

    Write-Log "Pubblicazione: $label"

    # Passa il testo via env var — evita ogni problema di quoting con virgolette nel testo
    $env:POST_MESSAGE   = $cleanText
    $env:POST_IMAGE_URL = if ($Post.ImageUrl) { $Post.ImageUrl } else { "" }

    if ($Post.Type -eq "Facebook") {
        $output = python $FbScript 2>&1
        $exitCode = $LASTEXITCODE

        if ($exitCode -eq 0 -and $output -match '^SUCCESS:') {
            $postId = ($output -split ':')[1]
            Write-Log "FB pubblicato OK. Post ID: $postId" "SUCCESS"
            return $true
        } else {
            Write-Log "FB errore (exitCode=$exitCode): $output" "ERROR"
            return $false
        }

    } elseif ($Post.Type -eq "Instagram") {
        $output = python $IgScript 2>&1
        $exitCode = $LASTEXITCODE

        try {
            $json = $output | ConvertFrom-Json
            if ($json.success -eq $true) {
                Write-Log "IG pubblicato OK. Post ID: $($json.post_id)" "SUCCESS"
                return $true
            } else {
                Write-Log "IG errore: $($json.error | ConvertTo-Json -Compress)" "ERROR"
                return $false
            }
        } catch {
            Write-Log "IG output non JSON (exitCode=$exitCode): $output" "ERROR"
            return $false
        }
    }

    Write-Log "Tipo post sconosciuto: $($Post.Type)" "ERROR"
    return $false
}

# ─────────────────────────────────────────────────────────────
# FUNZIONE: Inizializza repo locale, add e commit iniziale
# ─────────────────────────────────────────────────────────────
function Invoke-GitStart {
    param([string]$RepoDir)

    $gitDir = Join-Path $RepoDir ".git"

    if (Test-Path $gitDir) {
        Write-Log "GitStart: repo git già presente in $RepoDir" "WARN"
    } else {
        Write-Log "Inizializzazione repository git in $RepoDir" "INFO"
        git -C $RepoDir init 2>&1 | Out-Null
        Write-Log "Repository inizializzato" "SUCCESS"
    }

    $user  = $env:GITHUB_USER
    $repo  = $env:GITHUB_REPO
    $token = $env:GITHUB_TOKEN

    if (-not $user -or -not $repo -or -not $token) {
        Write-Log "GitStart: variabili GITHUB_USER / GITHUB_REPO / GITHUB_TOKEN mancanti in .env" "ERROR"
        exit 1
    }

    # Configura remote origin (sovrascrive se già presente)
    $existingRemote = git -C $RepoDir remote 2>&1
    $remoteUrl = "https://${token}@github.com/${user}/${repo}.git"
    if ($existingRemote -match 'origin') {
        git -C $RepoDir remote set-url origin $remoteUrl 2>&1 | Out-Null
        Write-Log "Remote origin aggiornato: github.com/$user/$repo" "INFO"
    } else {
        git -C $RepoDir remote add origin $remoteUrl 2>&1 | Out-Null
        Write-Log "Remote origin configurato: github.com/$user/$repo" "INFO"
    }

    # Configura identità git
    $gitName  = git -C $RepoDir config user.name 2>&1
    $gitEmail = git -C $RepoDir config user.email 2>&1
    if (-not $gitName)  { git -C $RepoDir config user.name  "publisher-bot" 2>&1 | Out-Null }
    if (-not $gitEmail) { git -C $RepoDir config user.email "bot@localhost"  2>&1 | Out-Null }

    # Add di tutti i file e commit iniziale
    git -C $RepoDir add . 2>&1 | Out-Null

    $staged = git -C $RepoDir diff --cached --name-only 2>&1
    if ([string]::IsNullOrWhiteSpace($staged)) {
        Write-Log "GitStart: nessun file da committare" "WARN"
        exit 0
    }

    $commitMsg = "init: primo commit $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    $commitOut = git -C $RepoDir commit -m $commitMsg 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Log "GitStart: commit creato - $commitMsg" "SUCCESS"
        Write-Log "Ora puoi eseguire: .\publisher.ps1 -GitPush" "INFO"
    } else {
        Write-Log "GitStart: commit fallito - $commitOut" "ERROR"
        exit 1
    }
}

# ─────────────────────────────────────────────────────────────
# FUNZIONE: Push su GitHub
# ─────────────────────────────────────────────────────────────
function Invoke-GitPush {
    param([string]$RepoDir)

    $gitDir = Join-Path $RepoDir ".git"
    if (-not (Test-Path $gitDir)) {
        Write-Log "GitPush: repo git non trovata in $RepoDir - esegui prima -GitStart" "ERROR"
        exit 1
    }

    $pushOut = git -C $RepoDir push -u origin HEAD 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Log "GitPush completato" "SUCCESS"
    } else {
        Write-Log "GitPush fallito: $pushOut" "ERROR"
        exit 1
    }
}

# ─────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────
Rotate-Log -LogPath $LogFile -MaxSizeMB $MaxLogSizeMB

Write-Log "========================================"
Write-Log "publisher.ps1 avviato"
if ($DryRun)    { Write-Log "Modo DRY-RUN attivo, nessuna pubblicazione reale" "WARN" }
if ($Debug)     { Write-Log "Modo DEBUG attivo" "DEBUG" }
if ($GitStart)  { Write-Log "Modalita' GitStart" "INFO" }
if ($GitPush)   { Write-Log "Modalita' GitPush" "INFO" }
Write-Log "========================================"

Import-EnvFile -Path $EnvFile

# Modalità one-shot: esegui e termina
if ($GitStart) {
    Invoke-GitStart -RepoDir $ScriptDir
    exit 0
}

if ($GitPush) {
    Invoke-GitPush -RepoDir $ScriptDir
    exit 0
}

# ─────────────────────────────────────────────────────────────
# LOOP CONTINUO
# ─────────────────────────────────────────────────────────────
Write-Log "Intervallo: $IntervalMinutes min | Tolleranza: $ToleranceMinutes min | MaxLog: ${MaxLogSizeMB}MB"

while ($true) {
    Rotate-Log -LogPath $LogFile -MaxSizeMB $MaxLogSizeMB

    $now = Get-Date
    Write-Log "--- Nuovo ciclo: $($now.ToString('yyyy-MM-dd HH:mm:ss')) ---"

    if (-not (Test-Path $PlanFile)) {
        Write-Log "plan.md non trovato: $PlanFile" "ERROR"
    } else {
        $pendingPosts = Read-PendingPosts -Path $PlanFile -Now $now -ToleranceMinutes $ToleranceMinutes

        if ($pendingPosts.Count -eq 0) {
            Write-Log "Nessun post da pubblicare in questo ciclo."
        } else {
            Write-Log "Post da pubblicare: $($pendingPosts.Count)"
            $published = 0

            foreach ($post in ($pendingPosts | Sort-Object Scheduled)) {
                $ok = Publish-Post -Post $post

                if ($ok) {
                    if (-not $DryRun) {
                        Update-PostStatus -Path $PlanFile `
                                          -LineIndex $post.StatusLineIndex `
                                          -NewStatus ([char]0x2705 + " published")
                    }
                    Write-Log "Status aggiornato: $($post.Type) $($post.Date) $($post.Time)" "SUCCESS"
                    $published++
                } else {
                    if (-not $DryRun) {
                        Update-PostStatus -Path $PlanFile `
                                          -LineIndex $post.StatusLineIndex `
                                          -NewStatus ([char]0x274C + " failed")
                    }
                    Write-Log "Status fallito: $($post.Type) $($post.Date) $($post.Time)" "ERROR"
                }
            }

        }
    }

    Write-Log "Prossimo ciclo tra $IntervalMinutes minuti. In attesa..."
    Start-Sleep -Seconds ($IntervalMinutes * 60)
}
