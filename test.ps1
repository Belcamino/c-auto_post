# test.ps1
# usage: test.ps1 messaggio [url image]

param (
    [Parameter(Mandatory=$true, Position=0, HelpMessage="Inserisci il messaggio da pubblicare")]
    [string]$Message,

    [Parameter(Mandatory=$false, Position=1, HelpMessage="Inserisci l'URL dell'immagine (opzionale)")]
    [string]$ImageUrl = ""
)

# 1. Verifica se il file .env esiste
if (Test-Path ".env") {
    Write-Host "Caricamento variabili da .env..." -ForegroundColor Cyan
    
    Get-Content .env | Where-Object { $_ -match '=' -and $_ -notmatch '^#' } | ForEach-Object {
        $parts = $_.Split('=', 2)
        $key = $parts[0].Trim()
        $value = $parts[1].Trim()
        
        Set-Item "env:$key" $value
    }
} else {
    Write-Warning "File .env non trovato. Gli script potrebbero fallire."
}

# 2. Esecuzione dello script Facebook (solitamente solo testo o link)
Write-Host "`n[FACEBOOK] Esecuzione di fb_publisher.py..." -ForegroundColor Green
python fb_publisher.py "$Message"

# 3. Esecuzione dello script Instagram
# Nota: Instagram richiede obbligatoriamente un'immagine per i post standard.
Write-Host "`n[INSTAGRAM] Esecuzione di ig_publisher.py..." -ForegroundColor Green

if (-not [string]::IsNullOrWhiteSpace($ImageUrl)) {
    # Se l'URL immagine è presente, lo passiamo come secondo argomento
    python ig_publisher.py "$Message" "$ImageUrl"
} else {
    # Se manca l'URL, eseguiamo solo con il messaggio (lo script Python dovrà gestire l'errore o usare un default)
    python ig_publisher.py "$Message"
}