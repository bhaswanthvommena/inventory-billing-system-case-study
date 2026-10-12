<#
.SYNOPSIS
  Fires N simultaneous sale requests for one product against a LOCAL DEMO instance
  and reports how many were accepted, rejected, and what stock remains.

.DESCRIPTION
  Purpose: demonstrate that the row-level locking around FIFO layers prevents overselling.
  With stock S, N requests of Q units each, at most floor(S / Q) may succeed.

  Run only against a throwaway demo database. It creates real sales there.

.EXAMPLE
  ./concurrency-check.ps1 -BaseUrl http://localhost:3100 -Username demo-admin `
      -Password $env:DEMO_ADMIN_PASSWORD -Sku DEMO-WP-009 -Requests 6 -UnitsEach 3
#>
param(
  [Parameter(Mandatory)] [string] $BaseUrl,
  [Parameter(Mandatory)] [string] $Username,
  [Parameter(Mandatory)] [string] $Password,
  [string] $Sku = 'DEMO-WP-009',
  [int] $Requests = 6,
  [int] $UnitsEach = 3,
  [decimal] $SellingPrice = 250
)

$ErrorActionPreference = 'Stop'

function New-Session {
  $s = New-Object Microsoft.PowerShell.Commands.WebRequestSession
  $body = @{ username = $Username; password = $Password } | ConvertTo-Json
  Invoke-WebRequest -Uri "$BaseUrl/api/auth/login" -Method POST -Body $body `
    -ContentType 'application/json' -WebSession $s -UseBasicParsing | Out-Null
  return $s
}

$admin = New-Session
$product = ((Invoke-WebRequest -Uri "$BaseUrl/api/products" -WebSession $admin -UseBasicParsing).Content |
  ConvertFrom-Json).products | Where-Object { $_.sku -eq $Sku }
if (-not $product) { throw "SKU $Sku not found" }
$before = [int]$product.currentStock
Write-Host "Stock before: $before. Sending $Requests concurrent requests for $UnitsEach unit(s) each."
Write-Host "Maximum that may succeed: $([math]::Floor($before / $UnitsEach))"

# Release all workers at the same instant.
$go = (Get-Date).AddSeconds(8)
$jobs = 1..$Requests | ForEach-Object {
  Start-Job -ArgumentList $BaseUrl, $Username, $Password, $product.id, $UnitsEach, $SellingPrice, $go, $_ -ScriptBlock {
    param($base, $user, $pass, $productId, $qty, $price, $go, $n)
    $s = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    Invoke-WebRequest -Uri "$base/api/auth/login" -Method POST -UseBasicParsing -WebSession $s `
      -ContentType 'application/json' -Body (@{ username = $user; password = $pass } | ConvertTo-Json) | Out-Null
    $payload = @{
      customerName = "Concurrency Test $n"
      items = @(@{ productId = $productId; quantity = $qty; sellingPrice = $price })
    } | ConvertTo-Json -Depth 5
    while ((Get-Date) -lt $go) { Start-Sleep -Milliseconds 5 }
    try {
      $r = Invoke-WebRequest -Uri "$base/api/sales" -Method POST -Body $payload -ContentType 'application/json' `
        -WebSession $s -UseBasicParsing
      [pscustomobject]@{ Request = $n; Status = [int]$r.StatusCode }
    } catch {
      [pscustomobject]@{ Request = $n; Status = [int]$_.Exception.Response.StatusCode }
    }
  }
}

$results = $jobs | Wait-Job | Receive-Job | Sort-Object Request
$jobs | Remove-Job

$results | Format-Table -AutoSize
$ok = @($results | Where-Object { $_.Status -eq 201 }).Count
$rejected = @($results | Where-Object { $_.Status -eq 409 }).Count

$after = [int]((((Invoke-WebRequest -Uri "$BaseUrl/api/products" -WebSession $admin -UseBasicParsing).Content |
  ConvertFrom-Json).products | Where-Object { $_.sku -eq $Sku }).currentStock)

Write-Host "Accepted (201): $ok   Rejected as insufficient stock (409): $rejected   Other: $($Requests - $ok - $rejected)"
Write-Host "Stock after: $after   Expected: $($before - $ok * $UnitsEach)"
if ($after -lt 0 -or $after -ne ($before - $ok * $UnitsEach)) { Write-Host 'FAIL: stock does not reconcile'; exit 1 }
if ($ok * $UnitsEach -gt $before) { Write-Host 'FAIL: oversold'; exit 1 }
Write-Host 'PASS: no oversell, stock reconciles with accepted sales.'
