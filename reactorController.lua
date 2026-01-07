local rla = peripheral.wrap("bottom")

if not rla then
    print("Error: Reactor Logic Adapter not found on BOTTOM!")
    return
end

-- Configuration
local targetEff = 100
local running = true
local lastErr = nil
local lastAdj = 0
local lastEff = nil
local direction = 1 -- 1 for UP, -1 for DOWN

-- Adaptive step parameters
local stepSize = 8
local minStep = 1
local maxStep = 50  -- Increased to allow large moves when CR far from TR

-- Reversal cooldown to avoid flip-flopping
local reversalCooldown = 0
local reversalCooldownMax = 2

-- Plasma temp tracking for heat multiplier & injection optimization
local lastTemp = nil
local tempTrend = 0 -- rising (+1), stable (0), falling (-1)
local lastCaseTemp = nil
local caseTempTrend = 0 -- detects if case is heating up

-- Injection sweet spot search parameters
local targetPlasmaTemp = 3200  -- aim for ~3200K (well below 4500K max) to minimize HM
local injectionSearchDir = 1   -- direction to search for optimal injection
local injectionCyclesSinceChange = 0
local injectionLockCycles = 8  -- cycles to hold injection steady if plasma stable
local bestInjection = 5
local bestTempStability = 999

local function drawUI(eff, adj, mode, err, cooldown)
    term.clear()
    term.setCursorPos(1,1)
    print("====================================")
    print("      FUSION REACTOR CONTROLLER     ")
    print("====================================")
    print(" Efficiency:  " .. string.format("%.2f", eff) .. "%")
    print(" Error Level: " .. string.format("%.2f", err))
    print("------------------------------------")
    print(" Mode:      " .. mode)
    local dirStr
    if adj > 0 then
        dirStr = "UP"
    elseif adj < 0 then
        dirStr = "DOWN"
    else
        dirStr = (direction == 1 and "UP" or "DOWN")
    end
    print(" Direction: " .. dirStr)
    print(" Last Adj:  " .. adj)
    
    if cooldown > 0 then
        local bar = string.rep("#", cooldown) .. string.rep("-", 5 - cooldown)
        print(" Logic Lock: [" .. bar .. "] " .. cooldown .. "s")
    else
        print(" Logic Lock: [READY]")
    end
    print("====================================")
    print("     PRESS ANY KEY TO STOP")
end

while running do
    if reversalCooldown and reversalCooldown > 0 then
        reversalCooldown = reversalCooldown - 1
    end
    local eff = rla.getEfficiency()
    local errLevel = rla.getErrorLevel()
    local curInj = rla.getInjectionRate()
    local minInj = 2 -- Safe minimum injection rate
    local maxCaseTemp = 9000 -- Safe maximum casing temperature
    local caseTemp = rla.getCaseTemperature()
    
    if eff > 0 then
        local adj = 0
        local mode = "SEEKING"
        local curTemp = rla.getPlasmaTemperature()

        -- Track plasma temp trend
        if lastTemp ~= nil then
            if curTemp > lastTemp + 1 then
                tempTrend = 1  -- rising
            elseif curTemp < lastTemp - 1 then
                tempTrend = -1  -- falling
            else
                tempTrend = 0  -- stable
            end
        end

        -- Track case temp trend (heat multiplier indicator)
        if lastCaseTemp ~= nil then
            if caseTemp > lastCaseTemp + 100 then
                caseTempTrend = 1  -- case heating up (heat multiplier climbing)
            elseif caseTemp < lastCaseTemp - 100 then
                caseTempTrend = -1  -- case cooling
            else
                caseTempTrend = 0  -- stable
            end
        end

        -- small helper: sign function
        local function s(x)
            if x > 0 then return 1 end
            if x < 0 then return -1 end
            return 0
        end

        -- Proportional target toward `targetEff` (tunable)
        -- Adaptive kp: aggressive when far, gentle when close
        local kp = 0.30
        if errLevel < 10 then
            kp = 0.05  -- Fine-tuning gain for small errors
        elseif errLevel < 20 then
            kp = 0.10  -- Medium gain
        elseif errLevel < 30 then
            kp = 0.20  -- Higher gain
        end
        
        local effErr = targetEff - eff
        local effSign = effErr > 0 and 1 or -1

        -- STABILITY ZONE: consider reactor stable when error low and efficiency near target
        if errLevel <= 5 and eff >= (targetEff - 0.25) then
            adj = 0
            mode = "STABLE LOCK"
            stepSize = math.max(minStep, math.floor(stepSize/2))
        else
            -- Start with efficiency-based sign
            local sign = effSign

            -- Use efficiency change (EF) alone to decide if previous move helped.
            if lastEff ~= nil and lastAdj ~= 0 then
                if eff > lastEff then
                    -- Efficiency improved: grow step and keep direction
                    stepSize = math.min(maxStep, stepSize + 2)
                    mode = "IMPROVING"
                    sign = s(lastAdj)
                else
                    -- Efficiency worsened: reverse or nudge opposite, with cooldown
                    if reversalCooldown == 0 then
                        direction = -direction
                        sign = -s(lastAdj)
                        stepSize = math.max(minStep, math.floor(stepSize / 2))
                        reversalCooldown = reversalCooldownMax
                        mode = "REVERSING"
                    else
                        sign = -s(lastAdj)
                        stepSize = math.max(minStep, math.floor(stepSize / 2))
                        mode = "COOLDOWN"
                    end
                end
            else
                -- No efficiency history: perform a small probe using efficiency sign * current direction
                sign = effSign * direction
                mode = "PROBING"
            end

            -- Proportional action based on efficiency gap (main control)
            local prop = math.ceil(math.abs(effErr) * kp)
            prop = math.max(minStep, math.min(maxStep, prop))
            adj = prop * sign

            -- If reactor error is VERY high (> 50), don't dampen—let it move aggressively
            if errLevel > 50 then
                -- Keep full adjustment, no dampening
                mode = "CRITICAL"
            elseif errLevel > 30 then
                -- Moderate dampening only for high error
                local mag = math.max(minStep, math.floor(math.abs(adj) / 1.5))
                adj = (adj > 0) and mag or -mag
            end

            -- Cap adjustment to current adaptive step size (but allow large moves when error extreme)
            if errLevel > 50 then
                -- Don't cap as aggressively when error is critical
                adj = (adj > 0) and math.max(minStep, math.min(maxStep, math.abs(adj))) or -math.max(minStep, math.min(maxStep, math.abs(adj)))
            else
                local cap = math.max(minStep, stepSize)
                local mag = math.max(minStep, math.min(cap, math.floor(math.abs(adj))))
                adj = (adj > 0) and mag or -mag
            end
            
            if errLevel > 50 then
                mode = "CRITICAL"
            elseif errLevel > 40 then
                mode = (mode == "REVERSING") and "REV-COARSE" or "COARSE"
            elseif errLevel > 15 then
                mode = (mode == "REVERSING") and "REV-APPROACH" or "APPROACHING"
            else
                mode = (mode == "REVERSING") and "REV-TUNING" or "TUNING"
            end
        end

        -- Improved Injection Optimization: bias toward lower injection when heat rises
        -- Goal: keep plasma near `targetPlasmaTemp` while actively preventing casing/heat-multiplier growth
        local injectionNeeded = curInj
        local tempError = curTemp - targetPlasmaTemp
        local tempStability = math.abs(tempError)

        -- Read heat multiplier if available (some RLA implementations provide this)
        local heatMult = nil
        if type(rla.getHeatMultiplier) == "function" then
            local ok, val = pcall(rla.getHeatMultiplier, rla)
            if ok then heatMult = val end
        end

        -- Compute a small heat penalty based on case temp trend, absolute case temp and heat multiplier
        local heatPenalty = 0
        if caseTemp ~= nil and lastCaseTemp ~= nil then
            if caseTemp > lastCaseTemp + 150 then heatPenalty = heatPenalty + 1 end
        end
        if caseTemp ~= nil and caseTemp > 5000 then heatPenalty = heatPenalty + 1 end
        if heatMult ~= nil and heatMult > 1.05 then heatPenalty = heatPenalty + 1 end

        -- Emergency safety: if casing already hot, force injection down quickly
        local emergencyReduce = false
        if caseTemp ~= nil and caseTemp > 8000 then
            emergencyReduce = true
        end

        if errLevel >= 50 then
            -- Critical: stabilize plasma first, but still prefer lowering injection when casing heats
            if curTemp > targetPlasmaTemp + 800 and curInj < 9 and not emergencyReduce then
                injectionNeeded = math.min(curInj + 1, 9)
            elseif emergencyReduce then
                injectionNeeded = math.max(minInj, curInj - 2)
            end
        else
            -- Normal mode: prefer lower injection if heat penalty exists
            if tempTrend == 0 and tempStability < 200 then
                injectionCyclesSinceChange = injectionCyclesSinceChange + 1
                injectionNeeded = curInj

                if tempStability < bestTempStability then
                    bestTempStability = tempStability
                    bestInjection = curInj
                    injectionLockCycles = 10
                end

                if injectionCyclesSinceChange >= injectionLockCycles then
                    -- Probe: only increase if no heat penalty, otherwise probe downward
                    if heatPenalty == 0 and curInj < 9 then
                        injectionNeeded = curInj + 1
                        injectionCyclesSinceChange = 0
                    elseif curInj > minInj then
                        injectionNeeded = curInj - 2
                        injectionCyclesSinceChange = 0
                    end
                end
            else
                injectionCyclesSinceChange = 0

                if curTemp > targetPlasmaTemp + 150 then
                    -- Too hot: reduce injection more aggressively when heat penalty present
                    local reduceBy = 1 + heatPenalty
                    if emergencyReduce then reduceBy = math.max(reduceBy, 2) end
                    injectionNeeded = math.max(minInj, curInj - reduceBy)
                elseif curTemp < targetPlasmaTemp - 150 then
                    -- Too cold: only increase if low heat penalty
                    if heatPenalty == 0 and curInj < 9 then
                        injectionNeeded = curInj + 1
                    else
                        injectionNeeded = curInj
                    end
                else
                    injectionNeeded = curInj
                end
            end
        end

        if injectionNeeded ~= curInj then
            -- Keep injection even and within bounds
            injectionNeeded = math.floor(math.max(minInj, math.min(9, injectionNeeded)) / 2) * 2
            if injectionNeeded ~= curInj then
                rla.setInjectionRate(injectionNeeded)
            end
        end

        lastTemp = curTemp
        lastCaseTemp = caseTemp

        -- Apply adjustment and record previous efficiency for trend detection
        lastErr = errLevel
        if adj ~= 0 then
            lastAdj = adj
            -- record eff before applying adj so next loop can compare
            lastEff = eff
            rla.adjustReactivity(adj)
            for i = 5, 1, -1 do
                drawUI(eff, adj, mode, errLevel, i)
                term.setCursorPos(1, 12)
                print(" Plasma Temp: " .. math.floor(curTemp) .. " K         ")
                print(" Case Temp:   " .. math.floor(caseTemp) .. " K         ")
                print(" Injection:   " .. string.format("%.2f", injectionNeeded) .. " (Min: " .. string.format("%.2f", minInj) .. ")")
                local timer = os.startTimer(1)
                repeat
                    local event = os.pullEvent()
                    if event == "key" then running = false end
                until event == "timer" or not running
                if not running then break end
            end
        else
            lastAdj = 0
            drawUI(eff, 0, mode, errLevel, 0)
            local timer = os.startTimer(1)
            repeat
                local event = os.pullEvent()
                if event == "key" then running = false end
            until event == "timer" or not running
        end
    else
        
        drawUI(0, 0, "OFFLINE", 0, 0)
        local timer = os.startTimer(2)
        repeat
            local event = os.pullEvent()
            if event == "key" then running = false end
        until event == "timer" or not running
    end
end

term.clear()
term.setCursorPos(1,1)
print("Controller Shutdown.")
