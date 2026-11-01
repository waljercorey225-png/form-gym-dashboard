$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$dataDirectory = Join-Path $root 'data'
$port = 4173
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$port/")
$sessions = @{}

function Get-CsvRows {
    [CmdletBinding()]
    param([string]$Name)
    return @(Import-Csv -LiteralPath (Join-Path $dataDirectory $Name) -WarningAction SilentlyContinue)
}

function Save-CsvRows {
    param(
        [string]$Name,
        [object[]]$Rows,
        [string[]]$Columns
    )
    $path = Join-Path $dataDirectory $Name
    $temporaryPath = "$path.tmp"
    $Rows = @($Rows)
    if ($Rows.Count -gt 0) {
        $Rows | Export-Csv -LiteralPath $temporaryPath -NoTypeInformation -Encoding UTF8
    } else {
        [System.IO.File]::WriteAllText($temporaryPath, ($Columns -join ',') + "`r`n", [System.Text.UTF8Encoding]::new($true))
    }
    Move-Item -LiteralPath $temporaryPath -Destination $path -Force
}

function Get-PlanIdForDate {
    param([string]$Date)
    $parsedDate = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($Date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsedDate)) { return -1 }
    return (([int]$parsedDate.DayOfWeek + 6) % 7)
}

function Send-Json {
    param($Context, [int]$StatusCode, $Body)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Body -Depth 12 -Compress))
    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = 'application/json; charset=utf-8'
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.Headers['Cache-Control'] = 'no-store'
    $Context.Response.Headers['X-Content-Type-Options'] = 'nosniff'
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.Close()
}

function Read-JsonBody {
    param($Context)
    $reader = New-Object System.IO.StreamReader($Context.Request.InputStream, $Context.Request.ContentEncoding)
    try {
        $rawBody = $reader.ReadToEnd()
        if (-not $rawBody) { return $null }
        return ConvertFrom-Json -InputObject $rawBody
    } finally {
        $reader.Dispose()
    }
}

function Get-GarminRecords {
    param([string]$FolderName, [string]$Pattern)
    $archive = Get-ChildItem -LiteralPath $dataDirectory -Directory | Where-Object { $_.Name -match '^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27}(_\d+)?$' } | Select-Object -First 1
    if (-not $archive) { return @() }
    $folder = Join-Path (Join-Path $archive.FullName 'DI_CONNECT') $FolderName
    if (-not (Test-Path -LiteralPath $folder)) { return @() }
    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($file in Get-ChildItem -LiteralPath $folder -Filter $Pattern -File) {
        try {
            $parsed = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            foreach ($record in @($parsed)) {
                if ($null -ne $record) { [void]$records.Add($record) }
            }
        } catch {}
    }
    return $records.ToArray()
}

function Get-MetricAverage {
    param([System.Collections.Generic.List[double]]$Values)
    if ($null -eq $Values -or $Values.Count -eq 0) { return $null }
    return [Math]::Round(($Values | Measure-Object -Average).Average, 1)
}

function Convert-GarminDateKey {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [ValueType] -and [double]$Value -gt 100000000000) {
        return [DateTimeOffset]::FromUnixTimeMilliseconds([long]$Value).UtcDateTime.ToString('yyyy-MM-dd')
    }
    $text = [string]$Value
    if ($text -match '^\d{4}-\d{2}-\d{2}$') { return $text }
    return $null
}

function Convert-GarminTimestamp {
    param($Value)
    if ($null -eq $Value -or [string]$Value -eq '') { return $null }
    if ($Value -is [datetime]) { return $Value }
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) { return $parsed }
    return $null
}

function Convert-ConnectDateKey {
    param([string]$Value)
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParseExact($Value, [string[]]@('yyyy-MM-dd', 'M/d/yyyy'), $culture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) { return $parsed.ToString('yyyy-MM-dd') }
    if ([datetime]::TryParseExact($Value, 'MMM d', $culture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        # Garmin Connect omits the year on some exports; use the most recent matching date.
        $parsed = $parsed.AddYears([datetime]::Today.Year - $parsed.Year)
        if ($parsed -gt [datetime]::Today) { $parsed = $parsed.AddYears(-1) }
        return $parsed.ToString('yyyy-MM-dd')
    }
    return $null
}

function Convert-ConnectNumber {
    param($Value)
    $number = 0.0
    if ([double]::TryParse(([string]$Value -replace '[^0-9.\-]', ''), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) { return $number }
    return $null
}

function Get-GarminConnectCsvMetrics {
    # Weekly CSV exports from Garmin Connect, dropped into data/garmin-connect. Each file is identified by its header.
    $days = @{}
    $folder = Join-Path $dataDirectory 'garmin-connect'
    if (-not (Test-Path -LiteralPath $folder)) { return $days }
    $culture = [Globalization.CultureInfo]::InvariantCulture
    foreach ($file in Get-ChildItem -LiteralPath $folder -Filter '*.csv' -File | Sort-Object LastWriteTime) {
        $rows = @(Import-Csv -LiteralPath $file.FullName -WarningAction SilentlyContinue)
        if (-not $rows.Count) { continue }
        $columns = @($rows[0].PSObject.Properties.Name)
        foreach ($row in $rows) {
            $date = Convert-ConnectDateKey ([string]$row.($columns[0]))
            if (-not $date) { continue }
            if (-not $days.ContainsKey($date)) { $days[$date] = @{} }
            $day = $days[$date]
            if ($columns -contains 'Sleep Score 7 Days') {
                $day.sleepScore = Convert-ConnectNumber $row.Score
                $day.respiration = Convert-ConnectNumber $row.Respiration
                if ($row.Duration -match '^(?:(\d+)h)?\s*(?:(\d+)min)?$') { $day.sleepMinutes = [int]$Matches[1] * 60 + [int]$Matches[2] }
                $bed = [datetime]::MinValue
                $wake = [datetime]::MinValue
                if ([datetime]::TryParseExact([string]$row.Bedtime, 'h:mm tt', $culture, [Globalization.DateTimeStyles]::None, [ref]$bed)) {
                    $day.bedtime = $bed.ToString('HH:mm')
                    if ([datetime]::TryParseExact([string]$row.'Wake Time', 'h:mm tt', $culture, [Globalization.DateTimeStyles]::None, [ref]$wake)) {
                        $inBed = ($wake - $bed).TotalMinutes
                        if ($inBed -le 0) { $inBed += 1440 }
                        $day.inBedMinutes = [int]$inBed
                    }
                }
            } elseif ($columns -contains 'Overnight HRV') {
                $day.hrv = Convert-ConnectNumber $row.'Overnight HRV'
            } elseif ($columns -contains 'Daily High') {
                $day.bodyBatteryHigh = Convert-ConnectNumber $row.'Daily High'
                $day.bodyBatteryLow = Convert-ConnectNumber $row.'Daily Low'
            } elseif ($columns -contains 'Resting Heart Rate') {
                $day.restingHeartRate = Convert-ConnectNumber $row.'Resting Heart Rate'
            } elseif ($columns -contains 'Stress') {
                $day.stress = Convert-ConnectNumber $row.Stress
            } elseif ($columns -contains 'Actual') {
                $day.steps = Convert-ConnectNumber $row.Actual
                $day.stepGoal = Convert-ConnectNumber $row.Goal
            }
        }
    }
    return $days
}

function Merge-DailyRows {
    param([object[]]$Rows, [hashtable]$Updates, [string[]]$Fields)
    # Updates map a date to @{ field = value }; non-null values replace the matching export row's field.
    $byDate = [ordered]@{}
    foreach ($row in $Rows) { $byDate[$row.date] = $row }
    foreach ($date in $Updates.Keys) {
        $values = $Updates[$date]
        $hasValue = $false
        foreach ($field in $Fields) { if ($null -ne $values[$field]) { $hasValue = $true } }
        if (-not $hasValue) { continue }
        if (-not $byDate.Contains($date)) {
            $blank = [ordered]@{ date = $date }
            foreach ($field in $Fields) { $blank[$field] = $null }
            $byDate[$date] = [pscustomobject]$blank
        }
        $target = $byDate[$date]
        foreach ($field in $Fields) {
            if ($null -eq $values[$field]) { continue }
            if ($target.PSObject.Properties[$field]) { $target.$field = $values[$field] }
            else { $target | Add-Member -NotePropertyName $field -NotePropertyValue $values[$field] }
        }
    }
    return @($byDate.Values)
}

function Get-GarminDashboardMetrics {
    $healthDays = @{}
    foreach ($record in Get-GarminRecords 'DI-Connect-Wellness' '*healthStatusData.json') {
        $date = [string]$record.calendarDate
        if ($date -notmatch '^\d{4}-\d{2}-\d{2}$') { continue }
        if (-not $healthDays.ContainsKey($date)) {
            $healthDays[$date] = @{
                date = $date
                heartRate = [System.Collections.Generic.List[double]]::new()
                hrv = [System.Collections.Generic.List[double]]::new()
                spo2 = [System.Collections.Generic.List[double]]::new()
                respiration = [System.Collections.Generic.List[double]]::new()
                skinTemperature = [System.Collections.Generic.List[double]]::new()
            }
        }
        foreach ($metric in $record.metrics) {
            if ($null -eq $metric.value) { continue }
            $number = 0.0
            if (-not [double]::TryParse([string]$metric.value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) { continue }
            $target = switch ([string]$metric.type) {
                'HR' { 'heartRate' }
                'HRV' { 'hrv' }
                'SPO2' { 'spo2' }
                'RESPIRATION' { 'respiration' }
                'SKIN_TEMP_C' { 'skinTemperature' }
                default { $null }
            }
            if ($target) { [void]$healthDays[$date][$target].Add($number) }
        }
    }
    $health = @($healthDays.Keys | Sort-Object | ForEach-Object {
        $day = $healthDays[$_]
        [pscustomobject]@{
            date = $day.date
            heartRate = Get-MetricAverage $day.heartRate
            hrv = Get-MetricAverage $day.hrv
            spo2 = Get-MetricAverage $day.spo2
            respiration = Get-MetricAverage $day.respiration
            skinTemperature = Get-MetricAverage $day.skinTemperature
        }
    })
    $readiness = @(Get-GarminRecords 'DI-Connect-Metrics' 'TrainingReadinessDTO_*.json' | Where-Object {
        $_.calendarDate -match '^\d{4}-\d{2}-\d{2}$' -and $null -ne $_.score
    } | ForEach-Object {
        [pscustomobject]@{ date = [string]$_.calendarDate; score = [int]$_.score }
    })
    $trainingLoadRows = [System.Collections.Generic.List[object]]::new()
    foreach ($record in Get-GarminRecords 'DI-Connect-Metrics' 'MetricsAcuteTrainingLoad_*.json') {
        $date = Convert-GarminDateKey $record.calendarDate
        if (-not $date) { continue }
        $ratioValue = if ($null -ne $record.acwrPercent) { $record.acwrPercent } else { $record.dailyAcuteChronicWorkloadRatio }
        [void]$trainingLoadRows.Add([pscustomobject]@{
            date = $date
            acute = if ($null -ne $record.dailyTrainingLoadAcute) { [Math]::Round([double]$record.dailyTrainingLoadAcute, 1) } else { $null }
            chronic = if ($null -ne $record.dailyTrainingLoadChronic) { [Math]::Round([double]$record.dailyTrainingLoadChronic, 1) } else { $null }
            ratio = if ($null -ne $ratioValue) { [Math]::Round([double]$ratioValue, 2) } else { $null }
        })
    }
    $trainingLoad = $trainingLoadRows.ToArray()
    $enduranceRows = [System.Collections.Generic.List[object]]::new()
    foreach ($record in Get-GarminRecords 'DI-Connect-Metrics' 'EnduranceScore_*.json') {
        $date = Convert-GarminDateKey $record.calendarDate
        if (-not $date -or $null -eq $record.overallScore) { continue }
        [void]$enduranceRows.Add([pscustomobject]@{ date = $date; score = [int]$record.overallScore })
    }
    $endurance = $enduranceRows.ToArray()
    $stressRows = [System.Collections.Generic.List[object]]::new()
    $batteryRows = [System.Collections.Generic.List[object]]::new()
    $dailyRows = [System.Collections.Generic.List[object]]::new()
    $utcOffsets = @{}
    $lastOffsetMinutes = 0
    foreach ($record in Get-GarminRecords 'DI-Connect-Aggregator' 'UDSFile_*.json') {
        $date = Convert-GarminDateKey $record.calendarDate
        if (-not $date) { continue }
        $localStart = Convert-GarminTimestamp $record.wellnessStartTimeLocal
        $gmtStart = Convert-GarminTimestamp $record.wellnessStartTimeGmt
        if ($localStart -and $gmtStart) { $utcOffsets[$date] = ($localStart - $gmtStart).TotalMinutes }
        $restingHeartRate = if ($null -ne $record.restingHeartRate) { [int]$record.restingHeartRate } elseif ($null -ne $record.currentDayRestingHeartRate) { [int]$record.currentDayRestingHeartRate } else { $null }
        $intensityMinutes = if ($null -ne $record.moderateIntensityMinutes -or $null -ne $record.vigorousIntensityMinutes) { [int]$record.moderateIntensityMinutes + 2 * [int]$record.vigorousIntensityMinutes } else { $null }
        $lowest = @($record.bodyBattery.bodyBatteryStatList | Where-Object { $_.bodyBatteryStatType -eq 'LOWEST' } | Select-Object -First 1)
        [void]$dailyRows.Add([pscustomobject]@{
            date = $date
            restingHeartRate = $restingHeartRate
            intensityMinutes = $intensityMinutes
            intensityGoal = if ($null -ne $record.userIntensityMinutesGoal) { [int]$record.userIntensityMinutesGoal } else { $null }
            steps = if ($null -ne $record.totalSteps) { [int]$record.totalSteps } else { $null }
            stepGoal = if ($null -ne $record.dailyStepGoal) { [int]$record.dailyStepGoal } else { $null }
            bodyBatteryLow = if ($lowest.Count -and $null -ne $lowest[0].statsValue -and [double]$lowest[0].statsValue -ge 0) { [int]$lowest[0].statsValue } else { $null }
        })
        $stress = @($record.allDayStress.aggregatorList | Where-Object { $_.type -eq 'TOTAL' } | Select-Object -First 1)
        if ($stress.Count -and $null -ne $stress[0].averageStressLevel -and [double]$stress[0].averageStressLevel -ge 0) {
            [void]$stressRows.Add([pscustomobject]@{ date = $date; value = [Math]::Round([double]$stress[0].averageStressLevel, 1) })
        }
        $battery = @($record.bodyBattery.bodyBatteryStatList | Where-Object { $_.bodyBatteryStatType -eq 'HIGHEST' } | Select-Object -First 1)
        if ($battery.Count -and $null -ne $battery[0].statsValue -and [double]$battery[0].statsValue -ge 0) {
            [void]$batteryRows.Add([pscustomobject]@{ date = $date; value = [Math]::Round([double]$battery[0].statsValue, 1) })
        }
    }
    if ($utcOffsets.Count) { $lastOffsetMinutes = $utcOffsets[($utcOffsets.Keys | Sort-Object | Select-Object -Last 1)] }
    $sleepRows = [System.Collections.Generic.List[object]]::new()
    foreach ($record in Get-GarminRecords 'DI-Connect-Wellness' '*sleepData.json') {
        $date = [string]$record.calendarDate
        if ($date -notmatch '^\d{4}-\d{2}-\d{2}$') { continue }
        $sleepSeconds = [int]$record.deepSleepSeconds + [int]$record.lightSleepSeconds + [int]$record.remSleepSeconds
        $start = Convert-GarminTimestamp $record.sleepStartTimestampGMT
        $end = Convert-GarminTimestamp $record.sleepEndTimestampGMT
        if ($utcOffsets.ContainsKey($date)) { $lastOffsetMinutes = $utcOffsets[$date] }
        [void]$sleepRows.Add([pscustomobject]@{
            date = $date
            durationMinutes = [Math]::Round($sleepSeconds / 60, 0)
            inBedMinutes = if ($start -and $end -and $end -gt $start) { [Math]::Round(($end - $start).TotalMinutes, 0) } else { $null }
            bedtime = if ($start) { $start.AddMinutes($lastOffsetMinutes).ToString('HH:mm') } else { $null }
            score = if ($null -ne $record.sleepScores.overallScore) { [int]$record.sleepScores.overallScore } else { $null }
            respiration = if ($null -ne $record.averageRespiration) { [Math]::Round([double]$record.averageRespiration, 1) } else { $null }
        })
    }
    $activityRows = [System.Collections.Generic.List[object]]::new()
    foreach ($export in Get-GarminRecords 'DI-Connect-Fitness' '*summarizedActivities.json') {
        foreach ($activity in @($export.summarizedActivitiesExport)) {
            # startTimeLocal is local wall-clock time stored as epoch milliseconds.
            $date = Convert-GarminDateKey $activity.startTimeLocal
            if (-not $date -or $null -eq $activity.duration) { continue }
            [void]$activityRows.Add([pscustomobject]@{
                id = [string]$activity.activityId
                date = $date
                startedAt = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$activity.startTimeLocal).UtcDateTime.ToString('HH:mm')
                name = [string]$activity.name
                type = [string]$activity.activityType
                durationMinutes = [int][Math]::Round([double]$activity.duration / 60000)
            })
        }
    }
    $connect = Get-GarminConnectCsvMetrics
    $pick = { param([hashtable]$Map) $result = @{}; foreach ($date in $connect.Keys) { $values = @{}; foreach ($pair in $Map.GetEnumerator()) { $values[$pair.Key] = $connect[$date][$pair.Value] }; $result[$date] = $values }; $result }
    return @{
        activities = $activityRows.ToArray()
        daily = Merge-DailyRows $dailyRows.ToArray() (& $pick @{ restingHeartRate = 'restingHeartRate'; bodyBatteryLow = 'bodyBatteryLow'; steps = 'steps'; stepGoal = 'stepGoal' }) @('restingHeartRate', 'bodyBatteryLow', 'steps', 'stepGoal')
        health = Merge-DailyRows $health (& $pick @{ hrv = 'hrv' }) @('hrv')
        sleep = Merge-DailyRows $sleepRows.ToArray() (& $pick @{ durationMinutes = 'sleepMinutes'; inBedMinutes = 'inBedMinutes'; bedtime = 'bedtime'; score = 'sleepScore'; respiration = 'respiration' }) @('durationMinutes', 'inBedMinutes', 'bedtime', 'score', 'respiration')
        readiness = $readiness
        trainingLoad = $trainingLoad
        endurance = $endurance
        stress = Merge-DailyRows $stressRows.ToArray() (& $pick @{ value = 'stress' }) @('value')
        bodyBattery = Merge-DailyRows $batteryRows.ToArray() (& $pick @{ value = 'bodyBatteryHigh' }) @('value')
    }
}

function Get-MemberForRequest {
    param($Request)
    $authorization = $Request.Headers['Authorization']
    if ($authorization -notmatch '^Bearer ([a-f0-9]{32})$') { return $null }
    $token = $Matches[1]
    if (-not $sessions.ContainsKey($token)) { return $null }
    $username = $sessions[$token]
    return Get-CsvRows 'members.csv' | Where-Object { $_.username -ceq $username -and $_.subscription_active -eq 'true' } | Select-Object -First 1
}

function Send-Dashboard {
    param($Context, $Member)
    $plans = @(Get-CsvRows 'plans.csv' | Sort-Object { [int]$_.day_index } | ForEach-Object {
        [pscustomobject]@{ planId = [int]$_.plan_id; dayIndex = [int]$_.day_index; title = $_.title; subtitle = $_.subtitle; duration = [int]$_.duration_minutes }
    })
    $exercises = @(Get-CsvRows 'exercises.csv' | ForEach-Object {
        [pscustomobject]@{ planId = [int]$_.plan_id; order = [int]$_.exercise_order; name = $_.exercise_name; details = $_.details; muscle = $_.muscle }
    })
    $completions = @(Get-CsvRows 'exercise_completions.csv' | Where-Object { $_.username -ceq $Member.username } | ForEach-Object {
        $planId = if ($_.plan_id -and $_.plan_id -ne '') { [int]$_.plan_id } else { Get-PlanIdForDate $_.date }
        $completed = if ($_.PSObject.Properties['completed'] -and $_.completed -ne '') { [bool]::Parse([string]$_.completed) } else { $true }
        $weight = if ($_.weight_kg -and $_.weight_kg -ne '') { [double]$_.weight_kg } else { $null }
        $sets = if ($_.PSObject.Properties['sets'] -and $_.sets -ne '') { [int]$_.sets } else { $null }
        $reps = if ($_.PSObject.Properties['reps'] -and $_.reps -ne '') { [int]$_.reps } else { $null }
        [pscustomobject]@{ date = $_.date; planId = $planId; exerciseOrder = [int]$_.exercise_order; completed = $completed; weightKg = $weight; sets = $sets; reps = $reps }
    })
    $workouts = @(Get-CsvRows 'sessions.csv' | Where-Object { $_.username -ceq $Member.username } | ForEach-Object {
        [pscustomobject]@{ id = $_.session_id; date = $_.date; planId = [int]$_.plan_id; durationMinutes = [int]$_.duration_minutes; exercisesCompleted = [int]$_.exercises_completed; completedAt = $_.completed_at }
    })
    $steps = @(Get-CsvRows 'Steps.csv' | ForEach-Object {
        $stepDate = [datetime]::ParseExact($_.H1, 'M/d/yyyy', [Globalization.CultureInfo]::InvariantCulture)
        [pscustomobject]@{ date = $stepDate.ToString('yyyy-MM-dd'); steps = [int]$_.Actual; goal = [int]$_.Goal }
    })
    $catalog = @(Get-CsvRows 'exercise_catalog.csv' | ForEach-Object {
        [pscustomobject]@{ exerciseId = $_.exercise_id; name = $_.name; category = $_.category; entryType = $_.entry_type; details = $_.details }
    })
    $exerciseLogs = @(Get-CsvRows 'exercise_logs.csv' | Where-Object { $_.username -ceq $Member.username } | ForEach-Object {
        [pscustomobject]@{
            id = $_.log_id
            exerciseId = $_.exercise_id
            exerciseName = $_.exercise_name
            category = $_.category
            entryType = $_.entry_type
            date = $_.date
            durationMinutes = if ($_.duration_minutes) { [int]$_.duration_minutes } else { $null }
            sets = if ($_.sets) { [int]$_.sets } else { $null }
            reps = if ($_.reps) { [int]$_.reps } else { $null }
            weightKg = if ($_.weight_kg) { [double]$_.weight_kg } else { $null }
            createdAt = $_.created_at
        }
    })
    $intensityLogs = @()
    if (Test-Path -LiteralPath (Join-Path $dataDirectory 'intensity_minutes.csv')) {
        $intensityLogs = @(Get-CsvRows 'intensity_minutes.csv' | Where-Object { $_.username -ceq $Member.username } | ForEach-Object {
            [pscustomobject]@{ date = $_.date; minutes = [int]$_.minutes }
        })
    }
    $restDays = @()
    if (Test-Path -LiteralPath (Join-Path $dataDirectory 'rest_days.csv')) {
        $restDays = @(Get-CsvRows 'rest_days.csv' | Where-Object { $_.username -ceq $Member.username } | ForEach-Object {
            [pscustomobject]@{ date = $_.date; planId = if ($_.PSObject.Properties['plan_id'] -and $_.plan_id -ne '') { [int]$_.plan_id } else { $null } }
        })
    }
    $vacations = @()
    if (Test-Path -LiteralPath (Join-Path $dataDirectory 'vacations.csv')) {
        $vacations = @(Get-CsvRows 'vacations.csv' | Where-Object { $_.username -ceq $Member.username } | ForEach-Object {
            [pscustomobject]@{ id = $_.vacation_id; startDate = $_.start_date; endDate = $_.end_date; label = $_.label }
        })
    }
    $stepEntries = @()
    if (Test-Path -LiteralPath (Join-Path $dataDirectory 'step_entries.csv')) {
        $stepEntries = @(Get-CsvRows 'step_entries.csv' | Where-Object { $_.username -ceq $Member.username } | ForEach-Object {
            [pscustomobject]@{ date = $_.date; steps = [int]$_.steps; goal = if ($_.goal) { [int]$_.goal } else { $null } }
        })
    }
    $garminMetrics = Get-GarminDashboardMetrics
    Send-Json $Context 200 @{
        stepEntries = $stepEntries
        restDays = $restDays
        vacations = $vacations
        intensityLogs = $intensityLogs
        member = @{ username = $Member.username; name = $Member.display_name; initials = $Member.initials; subscriptionActive = $true }
        plans = $plans
        exercises = $exercises
        completions = $completions
        sessions = $workouts
        steps = $steps
        catalog = $catalog
        exerciseLogs = $exerciseLogs
        garmin = $garminMetrics
    }
}

try {
    $listener.Start()
    Write-Host "FORM is running locally at http://localhost:$port/"
    Write-Host "CSV data is stored in $dataDirectory"
    Write-Host 'Press Ctrl+C to stop the local server.'
    while ($listener.IsListening) {
        try { $context = $listener.GetContext() } catch { break }
        try {
            $path = $context.Request.Url.AbsolutePath
            $method = $context.Request.HttpMethod
            if ($method -eq 'GET' -and ($path -eq '/' -or $path -eq '/index.html')) {
                $bytes = [System.IO.File]::ReadAllBytes((Join-Path $root 'index.html'))
                $context.Response.StatusCode = 200
                $context.Response.ContentType = 'text/html; charset=utf-8'
                $context.Response.ContentLength64 = $bytes.Length
                $context.Response.Headers['Cache-Control'] = 'no-store'
                $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $context.Response.Close()
                continue
            }
            if ($method -eq 'GET' -and $path -eq '/cloud-config.js') {
                $configPath = Join-Path $root 'cloud-config.js'
                if (-not (Test-Path -LiteralPath $configPath)) { Send-Json $context 404 @{ error = 'not_found' }; continue }
                $bytes = [System.IO.File]::ReadAllBytes($configPath)
                $context.Response.StatusCode = 200
                $context.Response.ContentType = 'text/javascript; charset=utf-8'
                $context.Response.ContentLength64 = $bytes.Length
                $context.Response.Headers['Cache-Control'] = 'no-store'
                $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $context.Response.Close()
                continue
            }
            if ($method -eq 'GET' -and $path -eq '/api/health') {
                Send-Json $context 200 @{ status = 'ok'; storage = 'local-csv' }
                continue
            }
            if ($method -eq 'POST' -and $path -eq '/api/login') {
                $body = Read-JsonBody $context
                $member = Get-CsvRows 'members.csv' | Where-Object { $_.username -ceq ([string]$body.username).Trim() -and $_.password -ceq [string]$body.password } | Select-Object -First 1
                if (-not $member) { Send-Json $context 401 @{ error = 'invalid_credentials' }; continue }
                if ($member.subscription_active -ne 'true') {
                    Send-Json $context 403 @{ error = 'subscription_inactive'; member = @{ username = $member.username; name = $member.display_name } }
                    continue
                }
                $token = [guid]::NewGuid().ToString('N')
                $sessions[$token] = $member.username
                Send-Json $context 200 @{ token = $token; member = @{ username = $member.username; name = $member.display_name; initials = $member.initials; subscriptionActive = $true } }
                continue
            }
            if ($method -eq 'POST' -and $path -eq '/api/logout') {
                $authorization = $context.Request.Headers['Authorization']
                if ($authorization -match '^Bearer ([a-f0-9]{32})$') { $sessions.Remove($Matches[1]) }
                Send-Json $context 200 @{ status = 'signed_out' }
                continue
            }
            $member = Get-MemberForRequest $context.Request
            if (-not $member) { Send-Json $context 401 @{ error = 'authentication_required' }; continue }
            if ($method -eq 'GET' -and $path -eq '/api/me') {
                Send-Json $context 200 @{ member = @{ username = $member.username; name = $member.display_name; initials = $member.initials; subscriptionActive = $true } }
                continue
            }
            if ($method -eq 'GET' -and $path -eq '/api/dashboard') {
                Send-Dashboard $context $member
                continue
            }
            if ($method -eq 'POST' -and $path -eq '/api/completions') {
                $body = Read-JsonBody $context
                $date = [string]$body.date
                $order = [int]$body.exerciseOrder
                $planId = [int]$body.planId
                $parsedDate = [datetime]::MinValue
                if ($date -notmatch '^\d{4}-\d{2}-\d{2}$' -or -not [datetime]::TryParseExact($date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsedDate) -or $order -lt 0 -or $planId -lt 0 -or $planId -gt 6) {
                    Send-Json $context 400 @{ error = 'invalid_completion' }; continue
                }
                $planIdText = [string]$planId
                $validExercise = Get-CsvRows 'exercises.csv' | Where-Object { $_.plan_id -eq $planIdText -and [int]$_.exercise_order -eq $order } | Select-Object -First 1
                if (-not $validExercise) { Send-Json $context 400 @{ error = 'unknown_exercise' }; continue }
                $weight = $null
                if ($null -ne $body.weightKg -and [string]$body.weightKg -ne '') {
                    $weight = [double]$body.weightKg
                    if ($weight -lt 0 -or $weight -gt 2000) { Send-Json $context 400 @{ error = 'invalid_weight' }; continue }
                }
                $sets = $null
                if ($null -ne $body.sets -and [string]$body.sets -ne '') {
                    $sets = [int]$body.sets
                    if ($sets -lt 1 -or $sets -gt 30) { Send-Json $context 400 @{ error = 'invalid_sets' }; continue }
                }
                $reps = $null
                if ($null -ne $body.reps -and [string]$body.reps -ne '') {
                    $reps = [int]$body.reps
                    if ($reps -lt 1 -or $reps -gt 100) { Send-Json $context 400 @{ error = 'invalid_reps' }; continue }
                }
                $keepRecord = [bool]$body.completed -or $null -ne $weight -or $null -ne $sets -or $null -ne $reps
                $rows = [System.Collections.Generic.List[object]]::new()
                foreach ($row in Get-CsvRows 'exercise_completions.csv') {
                    $existingPlanId = if ($row.plan_id -and $row.plan_id -ne '') { [int]$row.plan_id } else { Get-PlanIdForDate $row.date }
                    if ($row.username -ceq $member.username -and $row.date -ceq $date -and $existingPlanId -eq $planId -and [int]$row.exercise_order -eq $order) { continue }
                    $existingCompleted = if ($row.PSObject.Properties['completed'] -and $row.completed -ne '') { [bool]::Parse([string]$row.completed) } else { $true }
                    $existingWeight = if ($row.weight_kg -and $row.weight_kg -ne '') { [double]$row.weight_kg } else { $null }
                    $existingSets = if ($row.PSObject.Properties['sets'] -and $row.sets -ne '') { [int]$row.sets } else { $null }
                    $existingReps = if ($row.PSObject.Properties['reps'] -and $row.reps -ne '') { [int]$row.reps } else { $null }
                    [void]$rows.Add([pscustomobject]@{ username = $row.username; date = $row.date; plan_id = $existingPlanId; exercise_order = [int]$row.exercise_order; completed = $existingCompleted; weight_kg = $existingWeight; sets = $existingSets; reps = $existingReps; completed_at = $row.completed_at })
                }
                if ($keepRecord) {
                    [void]$rows.Add([pscustomobject]@{ username = $member.username; date = $date; plan_id = $planId; exercise_order = $order; completed = [bool]$body.completed; weight_kg = $weight; sets = $sets; reps = $reps; completed_at = [datetime]::UtcNow.ToString('o') })
                }
                Save-CsvRows -Name 'exercise_completions.csv' -Rows $rows.ToArray() -Columns @('username', 'date', 'plan_id', 'exercise_order', 'completed', 'weight_kg', 'sets', 'reps', 'completed_at')
                Send-Json $context 200 @{ status = 'saved'; completed = [bool]$body.completed; weightKg = $weight; sets = $sets; reps = $reps }
                continue
            }
            if ($method -eq 'POST' -and $path -eq '/api/sessions') {
                $body = Read-JsonBody $context
                $date = [string]$body.date
                $parsedDate = [datetime]::MinValue
                if ($date -notmatch '^\d{4}-\d{2}-\d{2}$' -or -not [datetime]::TryParseExact($date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsedDate)) {
                    Send-Json $context 400 @{ error = 'invalid_session_date' }; continue
                }
                $planId = [int]$body.planId
                $plan = Get-CsvRows 'plans.csv' | Where-Object { [int]$_.plan_id -eq $planId } | Select-Object -First 1
                if (-not $plan) {
                    Send-Json $context 400 @{ error = 'invalid_session' }; continue
                }
                $planExercises = @(Get-CsvRows 'exercises.csv' | Where-Object { [int]$_.plan_id -eq $planId })
                $completedCount = 0
                foreach ($row in Get-CsvRows 'exercise_completions.csv') {
                    $completionPlanId = if ($row.plan_id -and $row.plan_id -ne '') { [int]$row.plan_id } else { Get-PlanIdForDate $row.date }
                    $isComplete = if ($row.PSObject.Properties['completed'] -and $row.completed -ne '') { [bool]::Parse([string]$row.completed) } else { $true }
                    if ($row.username -ceq $member.username -and $row.date -ceq $date -and $completionPlanId -eq $planId -and $isComplete) { $completedCount += 1 }
                }
                $duration = [Math]::Max(1, [Math]::Min(600, [int]$body.durationMinutes))
                $rows = @(Get-CsvRows 'sessions.csv')
                $session = [pscustomobject]@{ session_id = [guid]::NewGuid().ToString('N'); username = $member.username; date = $date; plan_id = [int]$plan.plan_id; duration_minutes = $duration; exercises_completed = $completedCount; completed_at = [datetime]::UtcNow.ToString('o') }
                $rows += $session
                Save-CsvRows 'sessions.csv' $rows @('session_id', 'username', 'date', 'plan_id', 'duration_minutes', 'exercises_completed', 'completed_at')
                Send-Json $context 201 @{ status = 'logged'; id = $session.session_id; durationMinutes = $duration; completedAt = $session.completed_at; planTitle = $plan.title; exercisesAvailable = $planExercises.Count; exercisesCompleted = $completedCount }
                continue
            }
            if ($method -eq 'DELETE' -and $path -match '^/api/sessions/([a-f0-9]{32})$') {
                $sessionId = $Matches[1]
                $rows = @(Get-CsvRows 'sessions.csv')
                $owned = $rows | Where-Object { $_.session_id -ceq $sessionId -and $_.username -ceq $member.username } | Select-Object -First 1
                if (-not $owned) { Send-Json $context 404 @{ error = 'session_not_found' }; continue }
                $remaining = @($rows | Where-Object { -not ($_.session_id -ceq $sessionId -and $_.username -ceq $member.username) })
                Save-CsvRows 'sessions.csv' $remaining @('session_id', 'username', 'date', 'plan_id', 'duration_minutes', 'exercises_completed', 'completed_at')
                Send-Json $context 200 @{ status = 'deleted' }
                continue
            }
            if ($method -eq 'POST' -and $path -eq '/api/exercise-logs') {
                $body = Read-JsonBody $context
                $exerciseId = [string]$body.exerciseId
                $catalogItem = Get-CsvRows 'exercise_catalog.csv' | Where-Object { $_.exercise_id -ceq $exerciseId } | Select-Object -First 1
                $date = [string]$body.date
                $parsedDate = [datetime]::MinValue
                if (-not $catalogItem) { Send-Json $context 400 @{ error = 'unknown_exercise' }; continue }
                if ($date -notmatch '^\d{4}-\d{2}-\d{2}$' -or -not [datetime]::TryParseExact($date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsedDate)) {
                    Send-Json $context 400 @{ error = 'invalid_exercise_date' }; continue
                }
                $duration = $null
                $sets = $null
                $reps = $null
                $weight = $null
                if ($catalogItem.entry_type -eq 'time') {
                    $duration = [int]$body.durationMinutes
                    if ($duration -lt 1 -or $duration -gt 1440) { Send-Json $context 400 @{ error = 'invalid_duration' }; continue }
                } else {
                    $sets = [int]$body.sets
                    $reps = [int]$body.reps
                    if ($sets -lt 1 -or $sets -gt 30 -or $reps -lt 1 -or $reps -gt 100) { Send-Json $context 400 @{ error = 'invalid_sets_or_reps' }; continue }
                    if ($null -ne $body.weightKg -and [string]$body.weightKg -ne '') {
                        $weight = [double]$body.weightKg
                        if ($weight -lt 0 -or $weight -gt 2000) { Send-Json $context 400 @{ error = 'invalid_weight' }; continue }
                    }
                }
                $rows = @(Get-CsvRows 'exercise_logs.csv')
                $log = [pscustomobject]@{
                    log_id = [guid]::NewGuid().ToString('N')
                    username = $member.username
                    exercise_id = $catalogItem.exercise_id
                    exercise_name = $catalogItem.name
                    category = $catalogItem.category
                    entry_type = $catalogItem.entry_type
                    date = $date
                    duration_minutes = $duration
                    sets = $sets
                    reps = $reps
                    weight_kg = $weight
                    created_at = [datetime]::UtcNow.ToString('o')
                }
                $rows += $log
                Save-CsvRows 'exercise_logs.csv' $rows @('log_id', 'username', 'exercise_id', 'exercise_name', 'category', 'entry_type', 'date', 'duration_minutes', 'sets', 'reps', 'weight_kg', 'created_at')
                Send-Json $context 201 @{ status = 'logged'; exerciseLog = @{ id = $log.log_id; exerciseId = $log.exercise_id; exerciseName = $log.exercise_name; category = $log.category; entryType = $log.entry_type; date = $log.date; durationMinutes = $log.duration_minutes; sets = $log.sets; reps = $log.reps; weightKg = $log.weight_kg; createdAt = $log.created_at } }
                continue
            }
            if ($method -eq 'POST' -and $path -eq '/api/steps') {
                $body = Read-JsonBody $context
                $date = [string]$body.date
                $parsedDate = [datetime]::MinValue
                if ($date -notmatch '^\d{4}-\d{2}-\d{2}$' -or -not [datetime]::TryParseExact($date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsedDate)) {
                    Send-Json $context 400 @{ error = 'invalid_steps_date' }; continue
                }
                $steps = $null
                if ($null -ne $body.steps -and [string]$body.steps -ne '') {
                    $steps = [int]$body.steps
                    if ($steps -lt 0 -or $steps -gt 200000) { Send-Json $context 400 @{ error = 'invalid_steps' }; continue }
                }
                $goal = if ($null -ne $body.goal -and [int]$body.goal -gt 0) { [int]$body.goal } else { $null }
                $existing = @()
                if (Test-Path -LiteralPath (Join-Path $dataDirectory 'step_entries.csv')) { $existing = @(Get-CsvRows 'step_entries.csv') }
                $rows = @($existing | Where-Object { -not ($_.username -ceq $member.username -and $_.date -ceq $date) })
                if ($null -ne $steps) { $rows += [pscustomobject]@{ username = $member.username; date = $date; steps = $steps; goal = $goal; updated_at = [datetime]::UtcNow.ToString('o') } }
                Save-CsvRows 'step_entries.csv' $rows @('username', 'date', 'steps', 'goal', 'updated_at')
                Send-Json $context 200 @{ status = 'saved'; date = $date; steps = $steps; goal = $goal }
                continue
            }
            if ($method -eq 'POST' -and $path -eq '/api/rest-days') {
                $body = Read-JsonBody $context
                $date = [string]$body.date
                $parsedDate = [datetime]::MinValue
                if ($date -notmatch '^\d{4}-\d{2}-\d{2}$' -or -not [datetime]::TryParseExact($date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsedDate)) {
                    Send-Json $context 400 @{ error = 'invalid_rest_date' }; continue
                }
                $existing = @()
                if (Test-Path -LiteralPath (Join-Path $dataDirectory 'rest_days.csv')) { $existing = @(Get-CsvRows 'rest_days.csv') }
                $carriedPlanId = $null
                if ($null -ne $body.planId -and [string]$body.planId -ne '') {
                    $carriedPlanId = [int]$body.planId
                    if (-not (Get-CsvRows 'plans.csv' | Where-Object { [int]$_.plan_id -eq $carriedPlanId })) { Send-Json $context 400 @{ error = 'invalid_plan' }; continue }
                }
                $rows = @($existing | Where-Object { -not ($_.username -ceq $member.username -and $_.date -ceq $date) } | ForEach-Object {
                    [pscustomobject]@{ username = $_.username; date = $_.date; plan_id = if ($_.PSObject.Properties['plan_id']) { $_.plan_id } else { '' }; created_at = $_.created_at }
                })
                if ([bool]$body.rest) { $rows += [pscustomobject]@{ username = $member.username; date = $date; plan_id = $carriedPlanId; created_at = [datetime]::UtcNow.ToString('o') } }
                Save-CsvRows 'rest_days.csv' $rows @('username', 'date', 'plan_id', 'created_at')
                Send-Json $context 200 @{ status = 'saved'; date = $date; rest = [bool]$body.rest; planId = $carriedPlanId }
                continue
            }
            if ($method -eq 'POST' -and $path -eq '/api/vacations') {
                $body = Read-JsonBody $context
                $culture = [Globalization.CultureInfo]::InvariantCulture
                $start = [datetime]::MinValue
                $end = [datetime]::MinValue
                if (-not [datetime]::TryParseExact([string]$body.startDate, 'yyyy-MM-dd', $culture, [Globalization.DateTimeStyles]::None, [ref]$start) -or -not [datetime]::TryParseExact([string]$body.endDate, 'yyyy-MM-dd', $culture, [Globalization.DateTimeStyles]::None, [ref]$end) -or $end -lt $start -or ($end - $start).TotalDays -gt 366) {
                    Send-Json $context 400 @{ error = 'invalid_vacation_dates' }; continue
                }
                $label = ([string]$body.label).Trim()
                if ($label.Length -gt 60) { $label = $label.Substring(0, 60) }
                $rows = @()
                if (Test-Path -LiteralPath (Join-Path $dataDirectory 'vacations.csv')) { $rows = @(Get-CsvRows 'vacations.csv') }
                $vacation = [pscustomobject]@{ vacation_id = [guid]::NewGuid().ToString('N'); username = $member.username; start_date = $start.ToString('yyyy-MM-dd'); end_date = $end.ToString('yyyy-MM-dd'); label = $label; created_at = [datetime]::UtcNow.ToString('o') }
                $rows += $vacation
                Save-CsvRows 'vacations.csv' $rows @('vacation_id', 'username', 'start_date', 'end_date', 'label', 'created_at')
                Send-Json $context 201 @{ status = 'saved'; vacation = @{ id = $vacation.vacation_id; startDate = $vacation.start_date; endDate = $vacation.end_date; label = $vacation.label } }
                continue
            }
            if ($method -eq 'DELETE' -and $path -match '^/api/vacations/([a-f0-9]{32})$') {
                $vacationId = $Matches[1]
                $rows = @()
                if (Test-Path -LiteralPath (Join-Path $dataDirectory 'vacations.csv')) { $rows = @(Get-CsvRows 'vacations.csv') }
                $owned = $rows | Where-Object { $_.vacation_id -ceq $vacationId -and $_.username -ceq $member.username } | Select-Object -First 1
                if (-not $owned) { Send-Json $context 404 @{ error = 'vacation_not_found' }; continue }
                $remaining = @($rows | Where-Object { -not ($_.vacation_id -ceq $vacationId -and $_.username -ceq $member.username) })
                Save-CsvRows 'vacations.csv' $remaining @('vacation_id', 'username', 'start_date', 'end_date', 'label', 'created_at')
                Send-Json $context 200 @{ status = 'deleted' }
                continue
            }
            if ($method -eq 'POST' -and $path -eq '/api/intensity-minutes') {
                $body = Read-JsonBody $context
                $date = [string]$body.date
                $parsedDate = [datetime]::MinValue
                if ($date -notmatch '^\d{4}-\d{2}-\d{2}$' -or -not [datetime]::TryParseExact($date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsedDate)) {
                    Send-Json $context 400 @{ error = 'invalid_intensity_date' }; continue
                }
                $minutes = $null
                if ($null -ne $body.minutes -and [string]$body.minutes -ne '') {
                    $minutes = [int]$body.minutes
                    if ($minutes -lt 0 -or $minutes -gt 1440) { Send-Json $context 400 @{ error = 'invalid_intensity_minutes' }; continue }
                }
                $existing = @()
                if (Test-Path -LiteralPath (Join-Path $dataDirectory 'intensity_minutes.csv')) { $existing = @(Get-CsvRows 'intensity_minutes.csv') }
                $rows = [System.Collections.Generic.List[object]]::new()
                foreach ($row in $existing) {
                    if ($row.username -ceq $member.username -and $row.date -ceq $date) { continue }
                    [void]$rows.Add($row)
                }
                if ($null -ne $minutes) {
                    [void]$rows.Add([pscustomobject]@{ username = $member.username; date = $date; minutes = $minutes; updated_at = [datetime]::UtcNow.ToString('o') })
                }
                Save-CsvRows 'intensity_minutes.csv' $rows.ToArray() @('username', 'date', 'minutes', 'updated_at')
                Send-Json $context 200 @{ status = 'saved'; date = $date; minutes = $minutes }
                continue
            }
            if ($method -eq 'DELETE' -and $path -match '^/api/exercise-logs/([a-f0-9]{32})$') {
                $logId = $Matches[1]
                $rows = @(Get-CsvRows 'exercise_logs.csv')
                $ownedLog = $rows | Where-Object { $_.log_id -ceq $logId -and $_.username -ceq $member.username } | Select-Object -First 1
                if (-not $ownedLog) { Send-Json $context 404 @{ error = 'exercise_log_not_found' }; continue }
                $remaining = @($rows | Where-Object { -not ($_.log_id -ceq $logId -and $_.username -ceq $member.username) })
                Save-CsvRows 'exercise_logs.csv' $remaining @('log_id', 'username', 'exercise_id', 'exercise_name', 'category', 'entry_type', 'date', 'duration_minutes', 'sets', 'reps', 'weight_kg', 'created_at')
                Send-Json $context 200 @{ status = 'deleted' }
                continue
            }
            Send-Json $context 404 @{ error = 'not_found' }
        } catch {
            try { Send-Json $context 500 @{ error = 'local_server_error'; message = $_.Exception.Message } } catch {}
        }
    }
} finally {
    if ($listener.IsListening) { $listener.Stop() }
    $listener.Close()
}
