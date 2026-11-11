using Microsoft.Windows.EventTracing;
using Microsoft.Windows.EventTracing.Events;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace PerfParser
{
    internal static class PerfParser
    {
        private static readonly Guid GuidHoblInputInject = Guid.Parse("150a3791-7792-452d-858c-15d647ecb48f");
        private static readonly Guid GuidMicrosoftWindowsDiagTrack = Guid.Parse("43ac453b-97cd-4b51-4376-db7c9bb963ac");
        private static readonly Guid GuidWindowsTestInProduction = Guid.Parse("50109fbd-6d85-5815-731e-c907eca1607b");
        private static readonly Regex PtIdRegex = new(@"PT_\d+", RegexOptions.Compiled | RegexOptions.IgnoreCase);

        // PTs that fire before their InputInject tag instead of after it.
        private static readonly HashSet<string> FutureTagPtIds = new(StringComparer.OrdinalIgnoreCase) { "PT_9471" };

        // PTs that may fire repeatedly inside one transaction window; only the first is kept.
        private static readonly HashSet<string> FirstPerTransactionWindowPtIds = new(StringComparer.OrdinalIgnoreCase) { "PT_9412" };

        private sealed class ScenarioStartInfo
        {
            internal required string ScenarioInstanceId { get; init; }
            internal required string ScenarioName { get; set; }
            internal required string PtId { get; set; }
            internal required TraceTimestamp StartTimestamp { get; set; }
            internal required string StartTimestampText { get; set; }
            internal bool IsExplicitStart { get; set; }
        }

        private sealed record InputInjectInfo(TraceTimestamp Timestamp, string EventName, bool IsTransactionEnd);

        // A transaction. [StartMs, EndMs] is the declared interval, from a start tag to its
        // transactionend. RetentionEndMs is where PT retention resets — the next start tag —
        // so repeats that fire after the transaction closed still belong to this transaction.
        private sealed record TransactionWindow(decimal StartMs, decimal EndMs, decimal RetentionEndMs);

        private sealed record PerfTrackEventInfo(
            TraceTimestamp Timestamp,
            string PerfTrackEventName,
            string TaskName,
            string? PtId,
            string? ScenarioInstanceId,
            decimal? DurationMs,
            string? DurationSource);

        private sealed record ManifestIndex(
            HashSet<string> InterestedPtIds,
            Dictionary<string, string> PtDisplayNameById,
            Dictionary<string, string> PtDurationFieldById,
            Dictionary<Guid, List<PerftrackScenario>> ScenariosByProvider);

        private sealed record TraceData(
            List<ScenarioStartInfo> ScenarioStarts,
            List<InputInjectInfo> InputInjectEvents,
            List<PerfTrackEventInfo> PerfTrackEvents);

        // One finalized, ready-to-write output row: a single PT scenario completion,
        // correlated to its owning ScenarioInstance and (if applicable) its InputInject tag.
        private sealed record OutputRow(
            string ScenarioInstanceId,
            string ManifestScenarioName,
            string ScenarioStartTime,
            string PtId,
            string InputInjectEvent,
            decimal DurationMs,
            string? DurationSource,
            string CsvRowName);

        private sealed record CorrelatedPt(
            ScenarioStartInfo Scenario,
            string InputInjectEvent,
            PerfTrackEventInfo Event,
            decimal DurationMs,
            string? DurationSource);

        private sealed record PtRow(
            string ScenarioInstanceId,
            string ManifestScenarioName,
            string ScenarioStartTime,
            string PtId,
            string InputInjectEvent,
            decimal DurationMs,
            string? DurationSource,
            TraceTimestamp EventTimestamp,
            decimal IntervalStartMs,
            decimal IntervalEndMs);

        private static ManifestIndex BuildManifestIndex(IEnumerable<PerftrackScenario> scenarios)
        {
            HashSet<string> interestedPtIds = new(StringComparer.OrdinalIgnoreCase);
            Dictionary<string, string> ptDisplayNameById = new(StringComparer.OrdinalIgnoreCase);
            Dictionary<string, string> ptDurationFieldById = new(StringComparer.OrdinalIgnoreCase);
            Dictionary<Guid, List<PerftrackScenario>> scenariosByProvider = [];

            foreach (PerftrackScenario scenario in scenarios)
            {
                Match match = PtIdRegex.Match(scenario.ScenarioName);
                if (!match.Success)
                {
                    continue;
                }

                string ptId = match.Value.ToUpperInvariant();
                interestedPtIds.Add(ptId);

                if (!string.IsNullOrWhiteSpace(scenario.PtScenarioName) && !ptDisplayNameById.ContainsKey(ptId))
                {
                    ptDisplayNameById[ptId] = scenario.PtScenarioName;
                }

                if (!string.IsNullOrWhiteSpace(scenario.DurationField) && !ptDurationFieldById.ContainsKey(ptId))
                {
                    ptDurationFieldById[ptId] = scenario.DurationField;
                }

                foreach (Guid provider in scenario.StateMachine.Select(state => state.EventProvider).Distinct())
                {
                    if (!scenariosByProvider.TryGetValue(provider, out List<PerftrackScenario>? providerScenarios))
                    {
                        providerScenarios = [];
                        scenariosByProvider[provider] = providerScenarios;
                    }

                    providerScenarios.Add(scenario);
                }
            }

            return new ManifestIndex(
                interestedPtIds,
                ptDisplayNameById,
                ptDurationFieldById,
                scenariosByProvider);
        }

        private static string? SafeFieldToString(object? fieldValue)
        {
            if (fieldValue == null)
            {
                return null;
            }

            try
            {
                return fieldValue.ToString();
            }
            catch (NotSupportedException)
            {
                return null;
            }
            catch (InvalidOperationException)
            {
                // Some ETW fields throw when flag metadata does not match the value.
                return null;
            }
        }

        private static bool TryGetFieldValueCaseInsensitive(IGenericEvent ev, string fieldName, out string? value)
        {
            value = null;
            if (ev.Fields == null)
            {
                return false;
            }

            string qualifiedSuffix = "." + fieldName;

            foreach (string key in ev.Fields.Keys)
            {
                bool isMatch = key.Equals(fieldName, StringComparison.OrdinalIgnoreCase)
                    || key.EndsWith(qualifiedSuffix, StringComparison.OrdinalIgnoreCase);

                if (!isMatch)
                {
                    continue;
                }

                object? fieldObj;
                try
                {
                    fieldObj = ev.Fields[key];
                }
                catch (KeyNotFoundException)
                {
                    continue;
                }

                if (fieldObj == null)
                {
                    continue;
                }

                value = SafeFieldToString(fieldObj);
                return !string.IsNullOrWhiteSpace(value);
            }

            return false;
        }

        private static bool TryGetFieldInt64(IGenericEvent ev, string fieldName, out long value)
        {
            value = 0;
            if (!TryGetFieldValueCaseInsensitive(ev, fieldName, out string? text) || string.IsNullOrWhiteSpace(text))
            {
                return false;
            }

            text = text.Trim();
            if (long.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out value))
            {
                return true;
            }

            if (text.StartsWith("0x", StringComparison.OrdinalIgnoreCase)
                && long.TryParse(text[2..], NumberStyles.HexNumber, CultureInfo.InvariantCulture, out value))
            {
                return true;
            }

            if (decimal.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out decimal parsedDecimal))
            {
                value = decimal.ToInt64(decimal.Truncate(parsedDecimal));
                return true;
            }

            Match digits = Regex.Match(text, @"-?\d+");
            if (digits.Success && long.TryParse(digits.Value, NumberStyles.Integer, CultureInfo.InvariantCulture, out value))
            {
                return true;
            }

            return false;
        }

        private static readonly Regex RawEventAddressRegex = new(
            @"^(?<guid>[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\.(?<id>\d+)_(?<version>\d+)$",
            RegexOptions.Compiled);

        private static string BuildEventKey(IGenericEvent ev)
        {
            return $"{ev.ProviderName ?? "null"}.{ev.TaskName ?? "null"}";
        }

        private static bool TryParseRawEventAddress(string? eventName, out Guid providerId, out int id, out int version)
        {
            providerId = Guid.Empty;
            id = 0;
            version = 0;

            if (string.IsNullOrWhiteSpace(eventName))
            {
                return false;
            }

            // Classic ETW events are addressed as "{ProviderGuid}.{Id}_{Version}".
            Match match = RawEventAddressRegex.Match(eventName);
            if (!match.Success || !Guid.TryParse(match.Groups["guid"].Value, out providerId))
            {
                return false;
            }

            return int.TryParse(match.Groups["id"].Value, out id)
                && int.TryParse(match.Groups["version"].Value, out version);
        }

        private static bool EventMatchesStateName(IGenericEvent ev, string stateEventName, string eventKey)
        {
            if (TryParseRawEventAddress(stateEventName, out Guid rawProviderId, out int rawId, out int rawVersion))
            {
                return ev.ProviderId.Equals(rawProviderId) && ev.Id == rawId && ev.Version == rawVersion;
            }

            return stateEventName.Equals(eventKey, StringComparison.OrdinalIgnoreCase)
                || (!string.IsNullOrWhiteSpace(ev.TaskName)
                    && stateEventName.EndsWith($".{ev.TaskName}", StringComparison.OrdinalIgnoreCase));
        }

        private static bool IsTestResultEvent(IGenericEvent ev)
        {
            if (ev.ProviderId.Equals(GuidWindowsTestInProduction))
            {
                return true;
            }

            return !string.IsNullOrWhiteSpace(ev.TaskName)
                && ev.TaskName.Equals("TestResult", StringComparison.OrdinalIgnoreCase);
        }

        private static bool IsScenarioStartEvent(IGenericEvent ev)
        {
            return ev.ProviderId.Equals(GuidMicrosoftWindowsDiagTrack)
                && !string.IsNullOrWhiteSpace(ev.TaskName)
                && ev.TaskName.IndexOf("ScenarioStarted", StringComparison.OrdinalIgnoreCase) >= 0;
        }

        private static bool IsWpaLikePerfTrackRow(IGenericEvent ev)
        {
            if (ev.Fields == null)
            {
                return false;
            }

            if (ev.Fields.ContainsKey("IsSnapshot") && ev.Fields["IsSnapshot"] != null)
            {
                string? snapshotText = SafeFieldToString(ev.Fields["IsSnapshot"]);
                if (bool.TryParse(snapshotText, out bool isSnapshot) && isSnapshot)
                {
                    return false;
                }
            }

            return true;
        }

        private static bool TryParseDecimalInvariant(string? text, out decimal value)
        {
            value = 0;
            if (string.IsNullOrWhiteSpace(text))
            {
                return false;
            }

            return decimal.TryParse(text.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out value);
        }

        private static bool TryExtractNormalizedDurationMs(
            IGenericEvent ev,
            string? ptId,
            ManifestIndex manifestIndex,
            out decimal durationMs,
            out string durationSource)
        {
            durationMs = 0;
            durationSource = string.Empty;

            if (!string.IsNullOrWhiteSpace(ptId)
                && manifestIndex.PtDurationFieldById.TryGetValue(ptId, out string? manifestField)
                && !string.IsNullOrWhiteSpace(manifestField)
                && TryGetFieldValueCaseInsensitive(ev, manifestField, out string? manifestValue)
                && TryParseDecimalInvariant(manifestValue, out decimal manifestParsed)
                && manifestParsed > 0)
            {
                bool isSeconds = manifestField.Contains("(s)", StringComparison.OrdinalIgnoreCase)
                    || manifestField.Contains("Second", StringComparison.OrdinalIgnoreCase);

                durationMs = isSeconds ? manifestParsed * 1000m : manifestParsed;
                durationSource = $"Manifest:{manifestField}";
                return true;
            }

            if (TryGetFieldValueCaseInsensitive(ev, "ScenarioDurationMs", out string? scenarioDurationText)
                && TryParseDecimalInvariant(scenarioDurationText, out decimal scenarioDurationMs)
                && scenarioDurationMs > 0)
            {
                durationMs = scenarioDurationMs;
                durationSource = "ScenarioDurationMs";
                return true;
            }

            if (TryGetFieldValueCaseInsensitive(ev, "durationMs", out string? durationMsText)
                && TryParseDecimalInvariant(durationMsText, out decimal testDurationMs)
                && testDurationMs > 0)
            {
                durationMs = testDurationMs;
                durationSource = "durationMs";
                return true;
            }

            if (TryGetWpaDurationSeconds(ev, out decimal durationSeconds) && durationSeconds > 0)
            {
                durationMs = durationSeconds * 1000m;
                durationSource = "WpaDurationField";
                return true;
            }

            return false;
        }

        private static string ExtractInputInjectEventName(IGenericEvent ev)
        {
            if (ev.Fields != null && ev.Fields.ContainsKey("tag") && ev.Fields["tag"] != null)
            {
                string? tag = SafeFieldToString(ev.Fields["tag"]);
                if (!string.IsNullOrWhiteSpace(tag))
                {
                    return tag;
                }
            }

            if (!string.IsNullOrWhiteSpace(ev.TaskName))
            {
                return ev.TaskName!;
            }

            return "InputInject";
        }

        private static string EscapeCsvCell(string value)
        {
            if (value.Contains(',') || value.Contains('"') || value.Contains('\n') || value.Contains('\r'))
            {
                return $"\"{value.Replace("\"", "\"\"")}\"";
            }

            return value;
        }

        private static string FormatTimestamp(TraceTimestamp timestamp)
        {
            try
            {
                if (timestamp.HasValue)
                {
                    return timestamp.DateTimeOffset.ToString("O", CultureInfo.InvariantCulture);
                }
            }
            catch (ObjectDisposedException)
            {
                // Fall through to relative time fallback.
            }

            return timestamp.TotalMilliseconds.ToString(CultureInfo.InvariantCulture);
        }

        private static string? TryExtractPtIdFromText(string? text)
        {
            if (string.IsNullOrWhiteSpace(text))
            {
                return null;
            }

            Match match = PtIdRegex.Match(text);
            return match.Success ? match.Value.ToUpperInvariant() : null;
        }

        private static string? TryExtractScenarioName(IGenericEvent ev)
        {
            if (TryGetFieldValueCaseInsensitive(ev, "ScenarioName", out string? scenarioName) && !string.IsNullOrWhiteSpace(scenarioName))
            {
                return scenarioName;
            }

            if (TryGetFieldValueCaseInsensitive(ev, "Scenario", out scenarioName) && !string.IsNullOrWhiteSpace(scenarioName))
            {
                return scenarioName;
            }

            return null;
        }

        private static string? TryExtractScenarioInstanceId(IGenericEvent ev)
        {
            string[] fields = ["ScenarioInstanceId", "ScenarioInstanceID", "InstanceId", "ActivityId"];
            foreach (string field in fields)
            {
                if (TryGetFieldValueCaseInsensitive(ev, field, out string? value) && !string.IsNullOrWhiteSpace(value))
                {
                    return value;
                }
            }

            return null;
        }

        private static string? TryExtractPtIdFromEvent(IGenericEvent ev)
        {
            string? scenarioName = TryExtractScenarioName(ev);
            string? ptIdFromScenario = TryExtractPtIdFromText(scenarioName);
            if (!string.IsNullOrWhiteSpace(ptIdFromScenario))
            {
                return ptIdFromScenario;
            }

            if (ev.Fields == null)
            {
                return null;
            }

            foreach (string key in ev.Fields.Keys)
            {
                object? fieldObj;
                try
                {
                    fieldObj = ev.Fields[key];
                }
                catch (KeyNotFoundException)
                {
                    continue;
                }

                string? value = SafeFieldToString(fieldObj);
                string? ptId = TryExtractPtIdFromText(value);
                if (!string.IsNullOrWhiteSpace(ptId))
                {
                    return ptId;
                }
            }

            return null;
        }

        private static bool TryGetWpaDurationSeconds(IGenericEvent ev, out decimal durationSeconds)
        {
            durationSeconds = 0;

            if (ev.Fields == null)
            {
                return false;
            }

            decimal? bestValue = null;
            int bestScore = int.MinValue;

            foreach (string key in ev.Fields.Keys)
            {
                if (!key.Contains("Duration", StringComparison.OrdinalIgnoreCase) || ev.Fields[key] == null)
                {
                    continue;
                }

                string? text = SafeFieldToString(ev.Fields[key]);
                if (string.IsNullOrWhiteSpace(text))
                {
                    continue;
                }

                if (!decimal.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out decimal parsed))
                {
                    continue;
                }

                decimal seconds = key.Contains("ms", StringComparison.OrdinalIgnoreCase) ? parsed / 1000m : parsed;
                if (seconds < 0)
                {
                    continue;
                }

                int score = 0;
                if (seconds > 0)
                {
                    score += 1000;
                }

                if (key.Contains("(s)", StringComparison.OrdinalIgnoreCase) || key.Contains("Seconds", StringComparison.OrdinalIgnoreCase))
                {
                    score += 100;
                }

                if (key.Contains("ScenarioDuration", StringComparison.OrdinalIgnoreCase))
                {
                    score += 50;
                }

                if (score > bestScore)
                {
                    bestScore = score;
                    bestValue = seconds;
                }
            }

            if (!bestValue.HasValue)
            {
                return false;
            }

            durationSeconds = bestValue.Value;
            return true;
        }

        private static bool MatchesTriggerCondition(TriggerCondition condition, IGenericEvent ev)
        {
            if (!TryGetFieldValueCaseInsensitive(ev, condition.FieldName, out string? actualValue)
                || string.IsNullOrWhiteSpace(actualValue))
            {
                return false;
            }

            string op = condition.Operation.Trim();
            string actual = actualValue.Trim();
            string expected = condition.ExpectedValue.Trim();

            if (op.Equals("equal", StringComparison.OrdinalIgnoreCase))
            {
                if (decimal.TryParse(actual, NumberStyles.Float, CultureInfo.InvariantCulture, out decimal actualNum)
                    && decimal.TryParse(expected, NumberStyles.Float, CultureInfo.InvariantCulture, out decimal expectedNum))
                {
                    return actualNum == expectedNum;
                }

                return actual.Equals(expected, StringComparison.OrdinalIgnoreCase);
            }

            if (op.Equals("notequal", StringComparison.OrdinalIgnoreCase))
            {
                if (decimal.TryParse(actual, NumberStyles.Float, CultureInfo.InvariantCulture, out decimal actualNum)
                    && decimal.TryParse(expected, NumberStyles.Float, CultureInfo.InvariantCulture, out decimal expectedNum))
                {
                    return actualNum != expectedNum;
                }

                return !actual.Equals(expected, StringComparison.OrdinalIgnoreCase);
            }

            if (op.Equals("regex", StringComparison.OrdinalIgnoreCase))
            {
                try
                {
                    return Regex.IsMatch(actualValue, condition.ExpectedValue, RegexOptions.IgnoreCase);
                }
                catch (ArgumentException)
                {
                    return false;
                }
            }

            if (op.Equals("notregex", StringComparison.OrdinalIgnoreCase))
            {
                try
                {
                    return !Regex.IsMatch(actualValue, condition.ExpectedValue, RegexOptions.IgnoreCase);
                }
                catch (ArgumentException)
                {
                    return false;
                }
            }

            if (op.Equals("greaterthan", StringComparison.OrdinalIgnoreCase)
                || op.Equals("greaterthanequal", StringComparison.OrdinalIgnoreCase)
                || op.Equals("lessthan", StringComparison.OrdinalIgnoreCase)
                || op.Equals("lessthanequal", StringComparison.OrdinalIgnoreCase))
            {
                if (!decimal.TryParse(actual, NumberStyles.Float, CultureInfo.InvariantCulture, out decimal actualNum)
                    || !decimal.TryParse(expected, NumberStyles.Float, CultureInfo.InvariantCulture, out decimal expectedNum))
                {
                    return false;
                }

                if (op.Equals("greaterthan", StringComparison.OrdinalIgnoreCase))
                {
                    return actualNum > expectedNum;
                }

                if (op.Equals("greaterthanequal", StringComparison.OrdinalIgnoreCase))
                {
                    return actualNum >= expectedNum;
                }

                if (op.Equals("lessthan", StringComparison.OrdinalIgnoreCase))
                {
                    return actualNum < expectedNum;
                }

                return actualNum <= expectedNum;
            }

            return false;
        }

        private static bool TryExtractPerfTrackIdFromManifestRules(
            IGenericEvent ev,
            IReadOnlyList<PerftrackScenario> candidates,
            out string? ptId)
        {
            ptId = null;
            if (ev.Fields == null || candidates.Count == 0)
            {
                return false;
            }

            string eventKey = BuildEventKey(ev);
            int bestScore = -1;
            string? bestPt = null;

            foreach (PerftrackScenario candidate in candidates)
            {
                Match ptMatch = PtIdRegex.Match(candidate.ScenarioName);
                if (!ptMatch.Success)
                {
                    continue;
                }

                bool eventMatchesScenario = candidate.StateMachine.Any(state =>
                    state.EventProvider.Equals(ev.ProviderId)
                    && EventMatchesStateName(ev, state.EventName, eventKey));

                if (!eventMatchesScenario)
                {
                    // Providers are shared, so the declared state event must also match.
                    continue;
                }

                bool hasAnyRule = candidate.TriggerConditions.Count > 0 || candidate.ScriptFilterHints.Count > 0;
                if (!hasAnyRule)
                {
                    if (IsTestResultEvent(ev))
                    {
                        continue;
                    }

                    if (candidate.StateMachine.Count != 1)
                    {
                        continue;
                    }

                    if (string.IsNullOrWhiteSpace(candidate.DurationField)
                        || !TryGetFieldValueCaseInsensitive(ev, candidate.DurationField, out string? durationFieldValue)
                        || string.IsNullOrWhiteSpace(durationFieldValue))
                    {
                        continue;
                    }
                }

                bool matched = true;
                foreach (TriggerCondition condition in candidate.TriggerConditions)
                {
                    if (!MatchesTriggerCondition(condition, ev))
                    {
                        matched = false;
                        break;
                    }
                }

                if (!matched)
                {
                    continue;
                }

                bool hasHints = candidate.ScriptFilterHints.Count > 0;
                bool scriptMatched = !hasHints;

                if (hasHints)
                {
                    foreach (ScriptFilterHint hint in candidate.ScriptFilterHints)
                    {
                        bool hintOk = true;

                        if (hint.RequiredCompletionKind.HasValue)
                        {
                            if (!TryGetFieldInt64(ev, "completionKind", out long completionKind)
                                || completionKind != hint.RequiredCompletionKind.Value)
                            {
                                hintOk = false;
                            }
                        }

                        if (hintOk && hint.AllowedTestCaseIds.Count > 0)
                        {
                            if (!TryGetFieldInt64(ev, "testCaseId", out long testCaseId)
                                || !hint.AllowedTestCaseIds.Contains(testCaseId))
                            {
                                hintOk = false;
                            }
                        }

                        if (hintOk)
                        {
                            scriptMatched = true;
                            break;
                        }
                    }
                }

                if (!scriptMatched)
                {
                    continue;
                }

                int score = (hasAnyRule ? 100 : 0)
                    + candidate.TriggerConditions.Count
                    + (hasHints ? 10 : 0)
                    + (candidate.StateMachine.Count == 1 ? 5 : 0);
                if (score > bestScore)
                {
                    bestScore = score;
                    bestPt = ptMatch.Value.ToUpperInvariant();
                }
            }

            if (string.IsNullOrWhiteSpace(bestPt))
            {
                return false;
            }

            ptId = bestPt;
            return true;
        }

        private static string ResolvePerfTrackEventName(IGenericEvent ev, string? ptId, ManifestIndex manifestIndex)
        {
            if (!string.IsNullOrWhiteSpace(ptId) && manifestIndex.PtDisplayNameById.TryGetValue(ptId, out string? display))
            {
                return display;
            }

            string? scenarioName = TryExtractScenarioName(ev);
            if (!string.IsNullOrWhiteSpace(scenarioName))
            {
                return scenarioName;
            }

            if (!string.IsNullOrWhiteSpace(ev.TaskName))
            {
                return ev.TaskName!;
            }

            return BuildEventKey(ev);
        }

        private static TraceData ParseTrace(
            string etlPath,
            ManifestIndex manifestIndex)
        {
            List<InputInjectInfo> inputInjectEvents = [];
            List<PerfTrackEventInfo> perfTrackEvents = [];

            Dictionary<string, ScenarioStartInfo> scenarioByInstance = new(StringComparer.OrdinalIgnoreCase);

            using ITraceProcessor trace = TraceProcessor.Create(etlPath);
            HashSet<Guid> providerFilter =
            [
                GuidHoblInputInject,
                GuidMicrosoftWindowsDiagTrack,
                GuidWindowsTestInProduction,
                .. manifestIndex.ScenariosByProvider.Keys
            ];

            IPendingResult<IGenericEventDataSource> pendingGenericData = trace.UseGenericEvents();
            trace.Process();

            IEnumerable<IGenericEvent> events = pendingGenericData.Result.Events;

            foreach (IGenericEvent ev in events)
            {
                // The provider filter is the cheapest discriminator by far, and every downstream
                // extraction below scans the event's whole field collection. Reject out-of-scope
                // providers first so irrelevant events cost one hash lookup instead of several
                // full field scans plus regex matching.
                if (!providerFilter.Contains(ev.ProviderId))
                {
                    continue;
                }

                if (ev.ProviderId.Equals(GuidHoblInputInject))
                {
                    // transactionend carries no scenario identity, but it closes the window
                    // that scopes per-transaction PT retention, so it must be retained here.
                    string eventName = ExtractInputInjectEventName(ev);
                    bool isTransactionEnd = string.Equals(eventName, "transactionend", StringComparison.OrdinalIgnoreCase);
                    inputInjectEvents.Add(new InputInjectInfo(ev.Timestamp, eventName, isTransactionEnd));
                    continue;
                }

                string? eventScenarioInstanceId = TryExtractScenarioInstanceId(ev);
                string? eventScenarioName = TryExtractScenarioName(ev);
                string? resolvedPtId = TryExtractPtIdFromEvent(ev);
                if (string.IsNullOrWhiteSpace(resolvedPtId)
                    && manifestIndex.ScenariosByProvider.TryGetValue(ev.ProviderId, out List<PerftrackScenario>? providerScenarios)
                    && TryExtractPerfTrackIdFromManifestRules(ev, providerScenarios, out string? inferredPtId)
                    && !string.IsNullOrWhiteSpace(inferredPtId))
                {
                    resolvedPtId = inferredPtId;
                }

                // Prefer the manifest's human-readable PT scenario name.
                if (!string.IsNullOrWhiteSpace(resolvedPtId)
                    && manifestIndex.PtDisplayNameById.TryGetValue(resolvedPtId!, out string? manifestDisplayName)
                    && !string.IsNullOrWhiteSpace(manifestDisplayName))
                {
                    eventScenarioName = manifestDisplayName;
                }

                // Single-shot PTs need a synthetic instance for start/completion correlation.
                if (!string.IsNullOrWhiteSpace(resolvedPtId))
                {
                    if (string.IsNullOrWhiteSpace(eventScenarioInstanceId))
                    {
                        eventScenarioInstanceId = TryGetFieldValueCaseInsensitive(ev, "testId", out string? testId) && !string.IsNullOrWhiteSpace(testId)
                            ? testId
                            : $"{resolvedPtId}-{FormatTimestamp(ev.Timestamp)}";
                    }

                    if (string.IsNullOrWhiteSpace(eventScenarioName))
                    {
                        eventScenarioName = manifestIndex.PtDisplayNameById.TryGetValue(resolvedPtId!, out string? displayName) && !string.IsNullOrWhiteSpace(displayName)
                            ? displayName
                            : resolvedPtId;
                    }
                }

                if (!string.IsNullOrWhiteSpace(eventScenarioInstanceId)
                    && !string.IsNullOrWhiteSpace(eventScenarioName)
                    && !string.IsNullOrWhiteSpace(resolvedPtId))
                {
                    bool isExplicitStart = IsScenarioStartEvent(ev);

                    if (!scenarioByInstance.TryGetValue(eventScenarioInstanceId!, out ScenarioStartInfo? existingScenario))
                    {
                        scenarioByInstance[eventScenarioInstanceId!] = new ScenarioStartInfo
                        {
                            ScenarioInstanceId = eventScenarioInstanceId!,
                            ScenarioName = eventScenarioName!,
                            PtId = resolvedPtId!,
                            StartTimestamp = ev.Timestamp,
                            StartTimestampText = FormatTimestamp(ev.Timestamp),
                            IsExplicitStart = isExplicitStart
                        };
                    }
                    else if (isExplicitStart && !existingScenario.IsExplicitStart)
                    {
                        existingScenario.ScenarioName = eventScenarioName!;
                        existingScenario.PtId = resolvedPtId!;
                        existingScenario.StartTimestamp = ev.Timestamp;
                        existingScenario.StartTimestampText = FormatTimestamp(ev.Timestamp);
                        existingScenario.IsExplicitStart = true;
                    }
                    else if (isExplicitStart == existingScenario.IsExplicitStart
                        && ev.Timestamp < existingScenario.StartTimestamp)
                    {
                        existingScenario.ScenarioName = eventScenarioName!;
                        existingScenario.PtId = resolvedPtId!;
                        existingScenario.StartTimestamp = ev.Timestamp;
                        existingScenario.StartTimestampText = FormatTimestamp(ev.Timestamp);
                    }
                }

                if (!IsWpaLikePerfTrackRow(ev))
                {
                    continue;
                }

                // Only manifest-resolvable PT completions reach the output, so buffering events
                // without a PT id would just defer the same drop until correlation.
                if (string.IsNullOrWhiteSpace(resolvedPtId))
                {
                    continue;
                }

                TryExtractNormalizedDurationMs(ev, resolvedPtId, manifestIndex, out decimal normalizedMs, out string normalizedSource);

                perfTrackEvents.Add(new PerfTrackEventInfo(
                    ev.Timestamp,
                    ResolvePerfTrackEventName(ev, resolvedPtId, manifestIndex),
                    ev.TaskName ?? string.Empty,
                    resolvedPtId,
                    eventScenarioInstanceId,
                    normalizedMs > 0 ? normalizedMs : null,
                    normalizedMs > 0 ? normalizedSource : null));
            }

            List<InputInjectInfo> orderedInputInject = inputInjectEvents.OrderBy(i => i.Timestamp).ToList();

            return new TraceData(
                scenarioByInstance.Values.OrderBy(s => s.StartTimestamp).ToList(),
                orderedInputInject,
                perfTrackEvents.OrderBy(p => p.Timestamp).ToList());
        }

        private static InputInjectInfo? FindLatestInputInject(IReadOnlyList<InputInjectInfo> starts, TraceTimestamp timestamp)
        {
            int lo = 0;
            int hi = starts.Count - 1;
            int bestIndex = -1;

            while (lo <= hi)
            {
                int mid = lo + ((hi - lo) / 2);
                if (starts[mid].Timestamp <= timestamp)
                {
                    bestIndex = mid;
                    lo = mid + 1;
                }
                else
                {
                    hi = mid - 1;
                }
            }

            return bestIndex >= 0 ? starts[bestIndex] : null;
        }

        // PT_9471 fires before its InputInject tag; all other PTs fire after theirs.
        private static InputInjectInfo? FindNextInputInject(IReadOnlyList<InputInjectInfo> starts, TraceTimestamp timestamp)
        {
            int lo = 0;
            int hi = starts.Count - 1;
            int bestIndex = -1;

            while (lo <= hi)
            {
                int mid = lo + ((hi - lo) / 2);
                if (starts[mid].Timestamp >= timestamp)
                {
                    bestIndex = mid;
                    hi = mid - 1;
                }
                else
                {
                    lo = mid + 1;
                }
            }

            return bestIndex >= 0 ? starts[bestIndex] : null;
        }

        private static InputInjectInfo? FindInputInjectForPtId(string ptId, IReadOnlyList<InputInjectInfo> starts, TraceTimestamp timestamp)
        {
            return FutureTagPtIds.Contains(ptId)
                ? FindNextInputInject(starts, timestamp)
                : FindLatestInputInject(starts, timestamp);
        }

        // The InputInject stream is a flat, ordered mix of start tags and transactionend markers.
        // Each start tag opens a transaction that closes at its transactionend, while retention
        // for that transaction runs until the next start tag. A start tag that is followed by
        // another start tag before any transactionend was never closed, so its interval is
        // truncated at the next start tag. Built in one reverse pass.
        private static List<TransactionWindow> BuildTransactionWindows(IReadOnlyList<InputInjectInfo> inputInjectEvents)
        {
            List<TransactionWindow> windows = [];
            decimal nextStartMs = decimal.MaxValue;
            decimal nextEndMs = decimal.MaxValue;

            for (int i = inputInjectEvents.Count - 1; i >= 0; i--)
            {
                decimal timestampMs = inputInjectEvents[i].Timestamp.TotalMilliseconds;

                if (inputInjectEvents[i].IsTransactionEnd)
                {
                    nextEndMs = timestampMs;
                    continue;
                }

                windows.Add(new TransactionWindow(timestampMs, Math.Min(nextEndMs, nextStartMs), nextStartMs));
                nextStartMs = timestampMs;
            }

            windows.Reverse();
            return windows;
        }

        // Transactions tile the timeline from the first start tag onward, so the owning
        // transaction is the last one that opened at or before the timestamp. Returns -1 only
        // for PT events that precede the first InputInject start tag.
        private static int FindTransactionWindowIndex(IReadOnlyList<TransactionWindow> windows, decimal timestampMs)
        {
            int lo = 0;
            int hi = windows.Count - 1;
            int bestIndex = -1;

            while (lo <= hi)
            {
                int mid = lo + ((hi - lo) / 2);
                if (windows[mid].StartMs <= timestampMs)
                {
                    bestIndex = mid;
                    lo = mid + 1;
                }
                else
                {
                    hi = mid - 1;
                }
            }

            return bestIndex >= 0 && timestampMs < windows[bestIndex].RetentionEndMs ? bestIndex : -1;
        }

        private static string DescribeWindow(TransactionWindow window)
        {
            return $"[{FormatMs(window.StartMs)}, {FormatMs(window.EndMs)}]";
        }

        private static string FormatMs(decimal valueMs)
        {
            return valueMs == decimal.MaxValue
                ? "end of trace"
                : $"{valueMs.ToString("0.###", CultureInfo.InvariantCulture)}ms";
        }

        private static List<OutputRow> BuildFinalOutputRows(
            List<PerfTrackEventInfo> allPerfEvents,
            List<ScenarioStartInfo> scenarioStarts,
            List<InputInjectInfo> inputInjectEvents,
            HashSet<string> interestedPtIds)
        {
            Dictionary<string, ScenarioStartInfo> scenarioByInstance = scenarioStarts
                .ToDictionary(s => s.ScenarioInstanceId, StringComparer.OrdinalIgnoreCase);
            List<InputInjectInfo> inputInjectStarts = inputInjectEvents.Where(i => !i.IsTransactionEnd).ToList();
            List<TransactionWindow> transactionWindows = BuildTransactionWindows(inputInjectEvents);
            List<CorrelatedPt> correlatedPts = [];
            DropTally drops = new();

            foreach (PerfTrackEventInfo perfEvent in allPerfEvents)
            {
                if (!interestedPtIds.Contains(perfEvent.PtId!))
                {
                    drops.NotInManifest++;
                    continue;
                }

                if (perfEvent.DurationMs is not > 0)
                {
                    drops.NoDuration++;
                    continue;
                }

                if (string.IsNullOrWhiteSpace(perfEvent.ScenarioInstanceId)
                    || !scenarioByInstance.TryGetValue(perfEvent.ScenarioInstanceId, out ScenarioStartInfo? scenario)
                    || !scenario.PtId.Equals(perfEvent.PtId, StringComparison.OrdinalIgnoreCase))
                {
                    drops.NoScenarioInstance++;
                    continue;
                }

                InputInjectInfo? input = FindInputInjectForPtId(perfEvent.PtId!, inputInjectStarts, perfEvent.Timestamp);
                if (input == null)
                {
                    drops.NoInputInjectTag++;
                }

                correlatedPts.Add(new CorrelatedPt(
                    scenario,
                    input?.EventName ?? string.Empty,
                    perfEvent,
                    perfEvent.DurationMs.Value,
                    perfEvent.DurationSource));
            }

            List<PtRow> selectedRows = SelectBestPtRows(correlatedPts);
            List<PtRow> windowedRows = KeepFirstPerTransactionWindow(selectedRows, transactionWindows);
            List<PtRow> nonOverlappingRows = RemoveOverlappingRows(windowedRows);
            List<OutputRow> outputRows = AssignCsvRowNames(nonOverlappingRows);

            drops.Report(
                allPerfEvents.Count,
                correlatedPts.Count,
                selectedRows.Count,
                windowedRows.Count,
                nonOverlappingRows.Count,
                transactionWindows.Count);

            return outputRows;
        }

        // Per-row drop diagnostics are opt-in. Callers such as the HOBL harness capture stderr
        // and surface every line at error severity, so routine filtering would otherwise fill
        // their logs with alarming noise for a run that succeeded. Genuine faults stay on
        // stderr unconditionally.
        private static bool verboseDiagnostics;

        private static void LogInfo(string message)
        {
            if (verboseDiagnostics)
            {
                Console.Error.WriteLine(message);
            }
        }

        private sealed class DropTally
        {
            internal int NotInManifest;
            internal int NoDuration;
            internal int NoScenarioInstance;
            internal int NoInputInjectTag;

            internal void Report(
                int parsedEvents,
                int correlated,
                int selected,
                int windowed,
                int retained,
                int windowCount)
            {
                LogInfo(
                    $"[INFO] PT events parsed={parsedEvents} correlated={correlated} " +
                    $"(dropped: not-in-manifest={NotInManifest}, no-duration={NoDuration}, " +
                    $"no-scenario-instance={NoScenarioInstance})");
                LogInfo(
                    $"[INFO] Rows selected={selected} -> after transaction-window filter={windowed} " +
                    $"-> after overlap filter={retained} (transaction windows={windowCount}, " +
                    $"PT events with no InputInject tag={NoInputInjectTag})");
            }
        }

        private static List<PtRow> SelectBestPtRows(IEnumerable<CorrelatedPt> candidates)
        {
            Dictionary<string, (CorrelatedPt Pt, decimal DeltaMs)> bestByKey = new(StringComparer.OrdinalIgnoreCase);

            foreach (CorrelatedPt candidate in candidates)
            {
                string key = $"{candidate.Scenario.ScenarioInstanceId}::{candidate.Event.PtId}";
                decimal deltaMs = Math.Abs(
                    (candidate.Event.Timestamp - candidate.Scenario.StartTimestamp).TotalMilliseconds);
                int candidateScore = ScoreEvent(candidate);

                if (!bestByKey.TryGetValue(key, out var existing))
                {
                    bestByKey[key] = (candidate, deltaMs);
                    continue;
                }

                int existingScore = ScoreEvent(existing.Pt);
                if (candidateScore > existingScore
                    || (candidateScore == existingScore && deltaMs < existing.DeltaMs))
                {
                    bestByKey[key] = (candidate, deltaMs);
                }
            }

            return bestByKey.Values
                .Select(entry =>
                {
                    CorrelatedPt pt = entry.Pt;
                    decimal endMs = pt.Event.Timestamp.TotalMilliseconds;
                    return new PtRow(
                        pt.Scenario.ScenarioInstanceId,
                        pt.Scenario.ScenarioName,
                        pt.Scenario.StartTimestampText,
                        pt.Event.PtId!,
                        pt.InputInjectEvent,
                        pt.DurationMs,
                        pt.DurationSource,
                        pt.Event.Timestamp,
                        endMs - pt.DurationMs,
                        endMs);
                })
                .ToList();
        }

        private static int ScoreEvent(CorrelatedPt pt)
        {
            int score = pt.DurationSource switch
            {
                string source when source.Equals("ScenarioDurationMs", StringComparison.OrdinalIgnoreCase) => 200,
                string source when source.Equals("durationMs", StringComparison.OrdinalIgnoreCase) => 120,
                string source when source.StartsWith("Manifest:", StringComparison.OrdinalIgnoreCase) => 100,
                _ => 0
            };

            HashSet<string> scenarioWords = ExtractWordSet(pt.Event.PerfTrackEventName);
            HashSet<string> taskWords = ExtractWordSet(pt.Event.TaskName);
            return score + scenarioWords.Intersect(taskWords, StringComparer.OrdinalIgnoreCase).Count() * 40;
        }

        private static HashSet<string> ExtractWordSet(string text)
        {
            HashSet<string> words = new(StringComparer.OrdinalIgnoreCase);
            string symbolSplit = Regex.Replace(text, "[^A-Za-z0-9]+", " ");
            string camelSplit = Regex.Replace(symbolSplit, "([a-z0-9])([A-Z])", "$1 $2");

            foreach (Match match in Regex.Matches(camelSplit, "[A-Za-z]{3,}"))
            {
                words.Add(match.Value);
            }

            return words;
        }

        // Requirement: when two PT events overlap, keep the one that started first and drop the
        // later event whose start falls inside the retained event's active duration.
        //
        // Scope is per PT id rather than global. The requirement targets duplicate emissions of
        // one scenario, and a single PT cannot legitimately be measured twice at once, so an
        // overlapping repeat of the same PT is a duplicate and its later start is dropped.
        // Distinct PTs may legitimately nest, because a short sub-phase is often measured inside
        // a longer parent scenario: PT_9232 '_TIP_ Search Full Activation' (26ms) runs entirely
        // inside PT_9197 '_TIP_ Start Launch' (48ms). Comparing across PT ids deleted that row,
        // losing a real measurement, so cross-PT containment must not drop rows.
        //
        // One greedy sweep ordered by start time is sufficient, because a row can only be
        // shadowed by an earlier-starting row of the same PT. Ties on start time prefer the
        // longer interval so the retained row shadows the widest range.
        private static List<PtRow> RemoveOverlappingRows(IEnumerable<PtRow> rows)
        {
            List<PtRow> result = [];
            Dictionary<string, PtRow> retainedByPtId = new(StringComparer.OrdinalIgnoreCase);

            foreach (PtRow row in rows
                .OrderBy(row => row.IntervalStartMs)
                .ThenByDescending(row => row.IntervalEndMs))
            {
                if (retainedByPtId.TryGetValue(row.PtId, out PtRow? retained)
                    && row.IntervalStartMs < retained.IntervalEndMs)
                {
                    LogInfo(
                        $"[INFO] Dropped overlapping {row.PtId} '{BuildCsvRowKey(row)}' starting at " +
                        $"{FormatMs(row.IntervalStartMs)}, inside retained " +
                        $"'{BuildCsvRowKey(retained)}' " +
                        $"[{FormatMs(retained.IntervalStartMs)}, {FormatMs(retained.IntervalEndMs)}]");
                    continue;
                }

                result.Add(row);
                retainedByPtId[row.PtId] = row;
            }

            return result;
        }

        // Requirement: for PTs that fire repeatedly inside one InputInject transaction, display
        // only the first event occurring between the start tag and its transactionend. Every
        // other occurrence is dropped, including repeats that fire after the transaction closed
        // but before the next start tag, since retention only resets on a new start tag.
        private static List<PtRow> KeepFirstPerTransactionWindow(
            IEnumerable<PtRow> rows,
            IReadOnlyList<TransactionWindow> windows)
        {
            List<PtRow> result = [];
            HashSet<string> retainedTransactions = new(StringComparer.OrdinalIgnoreCase);

            foreach (PtRow row in rows.OrderBy(row => row.EventTimestamp.TotalMilliseconds))
            {
                if (!FirstPerTransactionWindowPtIds.Contains(row.PtId))
                {
                    result.Add(row);
                    continue;
                }

                decimal timestampMs = row.EventTimestamp.TotalMilliseconds;
                int index = FindTransactionWindowIndex(windows, timestampMs);
                if (index < 0)
                {
                    result.Add(row);
                    continue;
                }

                TransactionWindow window = windows[index];

                if (timestampMs > window.EndMs)
                {
                    LogInfo(
                        $"[INFO] Dropped {row.PtId} '{BuildCsvRowKey(row)}' at {FormatMs(timestampMs)}: " +
                        $"fired after transaction {DescribeWindow(window)} closed, before the next start tag");
                    continue;
                }

                if (!retainedTransactions.Add($"{row.PtId}::{index}"))
                {
                    LogInfo(
                        $"[INFO] Dropped {row.PtId} '{BuildCsvRowKey(row)}' at {FormatMs(timestampMs)}: " +
                        $"repeat within transaction {DescribeWindow(window)}");
                    continue;
                }

                result.Add(row);
            }

            return result;
        }

        // Requirement: the first row for a key keeps the bare key; every later row with the same
        // key gets an incrementing _1, _2 ... suffix.
        private static List<OutputRow> AssignCsvRowNames(IEnumerable<PtRow> rows)
        {
            Dictionary<string, int> occurrencesByKey = new(StringComparer.OrdinalIgnoreCase);

            return rows
                .OrderBy(row => row.IntervalStartMs)
                .Select(row =>
                {
                    string key = BuildCsvRowKey(row);
                    int occurrence = occurrencesByKey.GetValueOrDefault(key);
                    occurrencesByKey[key] = occurrence + 1;

                    return new OutputRow(
                        row.ScenarioInstanceId,
                        row.ManifestScenarioName,
                        row.ScenarioStartTime,
                        row.PtId,
                        row.InputInjectEvent,
                        row.DurationMs,
                        row.DurationSource,
                        occurrence == 0 ? key : $"{key}_{occurrence}");
                })
                .ToList();
        }

        private static string BuildCsvRowKey(PtRow row)
        {
            return string.IsNullOrWhiteSpace(row.InputInjectEvent)
                ? $"Perftrack_{row.ManifestScenarioName}"
                : $"Perftrack_{row.InputInjectEvent}_{row.ManifestScenarioName}";
        }

        private static void WriteSummaryCsv(string path, List<OutputRow> rows)
        {
            StringBuilder csv = new();

            foreach (OutputRow row in rows)
            {
                csv.Append(EscapeCsvCell(row.CsvRowName)).Append(',')
                   .Append(row.DurationMs.ToString("0.###", CultureInfo.InvariantCulture))
                   .AppendLine();
            }

            File.AppendAllText(path, csv.ToString());
        }

        private static void WriteRawMetricsTxt(string path, List<OutputRow> rows)
        {
            StringBuilder csv = new();
            csv.AppendLine("ScenarioInstanceID,Scenario Start Time,Scenario Name,PT_ID,Corresponding Input Inject Event,DurationMs,DurationSource");

            foreach (OutputRow row in rows)
            {
                csv.Append(EscapeCsvCell(row.ScenarioInstanceId)).Append(',')
                   .Append(EscapeCsvCell(row.ScenarioStartTime)).Append(',')
                   .Append(EscapeCsvCell(row.ManifestScenarioName)).Append(',')
                   .Append(EscapeCsvCell(row.PtId)).Append(',')
                   .Append(EscapeCsvCell(row.InputInjectEvent)).Append(',')
                   .Append(row.DurationMs.ToString("0.###", CultureInfo.InvariantCulture)).Append(',')
                   .Append(EscapeCsvCell(row.DurationSource ?? string.Empty))
                   .AppendLine();
            }

            File.WriteAllText(path, csv.ToString());
        }

        private static string BuildDefaultSummaryPath(string etlPath)
        {
            string directory = Path.GetDirectoryName(etlPath) ?? ".";
            string baseName = Path.GetFileNameWithoutExtension(etlPath);
            return Path.Combine(directory, $"{baseName}_scenario_duration.csv");
        }

        private static string BuildDefaultRawMetricsPath(string etlPath)
        {
            string directory = Path.GetDirectoryName(etlPath) ?? ".";
            string baseName = Path.GetFileNameWithoutExtension(etlPath);
            return Path.Combine(directory, $"{baseName}_raw_metrics.txt");
        }

        private static int Main(string[] args)
        {
            const string usage = "Usage: PerfParser <etlPath> <xmlManifestPath> [summaryCsvPath] [--raw-metrics [rawMetricsTxtPath]] [--verbose]";

            // The raw metrics txt is opt-in via --raw-metrics, per user request, rather than
            // always being written alongside the summary CSV. Positional args are collected
            // separately from the flag so existing "<etl> <xml> [summary]" invocations keep working.
            List<string> positional = new();
            bool writeRawMetrics = false;
            string? rawMetricsArgPath = null;

            for (int i = 0; i < args.Length; i++)
            {
                if (args[i].Equals("--raw-metrics", StringComparison.OrdinalIgnoreCase))
                {
                    writeRawMetrics = true;
                    if (i + 1 < args.Length && !args[i + 1].StartsWith("--", StringComparison.Ordinal))
                    {
                        rawMetricsArgPath = args[++i];
                    }
                    continue;
                }

                if (args[i].Equals("--verbose", StringComparison.OrdinalIgnoreCase))
                {
                    verboseDiagnostics = true;
                    continue;
                }

                positional.Add(args[i]);
            }

            if (positional.Count < 2 || positional.Count > 3)
            {
                Console.Error.WriteLine(usage);
                return 1;
            }

            string etlPath = positional[0];
            string xmlManifestPath = positional[1];
            string summaryCsvPath = positional.Count >= 3 ? positional[2] : BuildDefaultSummaryPath(etlPath);
            string rawMetricsTxtPath = rawMetricsArgPath ?? BuildDefaultRawMetricsPath(etlPath);

            try
            {
                List<PerftrackScenario> scenarios = ScenarioManifestHandler.LoadScenarios(xmlManifestPath);
                ManifestIndex manifestIndex = BuildManifestIndex(scenarios);

                TraceData traceData = ParseTrace(etlPath, manifestIndex);

                List<OutputRow> outputRows = BuildFinalOutputRows(
                    traceData.PerfTrackEvents,
                    traceData.ScenarioStarts,
                    traceData.InputInjectEvents,
                    manifestIndex.InterestedPtIds);

                WriteSummaryCsv(summaryCsvPath, outputRows);
                Console.WriteLine($"Summary CSV written: {summaryCsvPath} ({outputRows.Count} rows)");

                if (outputRows.Count == 0)
                {
                    Console.Error.WriteLine(
                        "[WARN] No PerfTrack rows were produced. Verify the manifest matches the trace.");
                }

                if (writeRawMetrics)
                {
                    WriteRawMetricsTxt(rawMetricsTxtPath, outputRows);
                    Console.WriteLine($"Raw metrics TXT written: {rawMetricsTxtPath}");
                }

                return 0;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"[ERROR] Unhandled exception: {ex}");
                return 1;
            }
        }
    }
}
