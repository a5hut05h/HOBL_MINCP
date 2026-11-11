using System.Xml;

namespace PerfParser
{
    internal sealed record ScriptFilterHint(long? RequiredCompletionKind, HashSet<long> AllowedTestCaseIds);

    internal sealed record TriggerCondition(string FieldName, string Operation, string ExpectedValue);

    internal sealed record State(string EventName, Guid EventProvider);

    internal sealed record PerftrackScenario(
        string ScenarioName,
        string? PtScenarioName,
        string? DurationField,
        IReadOnlyList<State> StateMachine,
        IReadOnlyList<TriggerCondition> TriggerConditions,
        IReadOnlyList<ScriptFilterHint> ScriptFilterHints);

    internal static class ScenarioManifestHandler
    {
        internal static List<PerftrackScenario> LoadScenarios(string xmlPath)
        {
            List<PerftrackScenario> scenarios = [];
            Dictionary<string, Guid> eventProvider = [];
            List<(State State, int Index)> states = [];
            List<TriggerCondition> triggerConditions = [];
            List<ScriptFilterHint> scriptFilterHints = [];

            using XmlReader reader = XmlReader.Create(xmlPath);
            string? stateId = null;
            string? scenarioName = null;
            string? ptName = null;
            string? durationField = null;
            string? triggerName = null;
            bool validScenario = true;
            string? filterApplyTarget = null;
            bool inSingleTriggerFilter = false;
            string? currentSingleTriggerEvent = null;
            string? currentSingleTriggerField = null;
            string? currentSingleTriggerOperation = null;
            string? currentSingleTriggerValue = null;
            string? currentFilterName = null;

            bool inScriptFilter = false;
            Dictionary<string, string> scriptVarToField = [];
            string? currentScriptEqualVar = null;
            List<(string varName, string constValue)> scriptEquals = [];

            bool inTransition = false;
            int pendingTransitionStateIndex = -1;
            string? pendingTransitionEventName = null;
            bool pendingTransitionIsValid = false;

            while (reader.Read())
            {
                if (reader.IsStartElement())
                {
                    if (reader.Name.Equals("scenario"))
                    {
                        scenarioName = reader.GetAttribute("scenarioname");
                        if (scenarioName == null)
                        {
                            validScenario = false;
                            Console.WriteLine("Error: Scenario name is null");
                        }

                        ptName = reader.GetAttribute("ptscenarioname");
                        durationField = reader.GetAttribute("ptdurationfield");
                    }
                    else if (inTransition
                        && reader.Name.Equals("filter")
                        && reader.GetAttribute("appliesto") == null)
                    {
                        if (!reader.IsEmptyElement)
                        {
                            reader.ReadElementContentAsString();
                        }
                    }
                    else if (reader.Name.Equals("filter"))
                    {
                        filterApplyTarget = reader.GetAttribute("appliesto");
                        currentFilterName = reader.GetAttribute("filtername");
                    }
                    else if (reader.Name.Equals("trigger"))
                    {
                        triggerName = reader.GetAttribute("triggername");
                    }
                    else if (reader.Name.Equals("singletriggerpropertyfilter") && filterApplyTarget == "trigger")
                    {
                        inSingleTriggerFilter = true;
                        currentSingleTriggerEvent = reader.GetAttribute("triggername");
                        currentSingleTriggerField = null;
                        currentSingleTriggerOperation = null;
                        currentSingleTriggerValue = null;
                    }
                    else if (reader.Name.Equals("scriptfilter") && filterApplyTarget == "trigger")
                    {
                        inScriptFilter = true;
                        scriptVarToField.Clear();
                        scriptEquals.Clear();
                        currentScriptEqualVar = null;
                    }
                    else if (inSingleTriggerFilter && reader.Name.Equals("triggername") && currentSingleTriggerEvent == null)
                    {
                        // The manifest encodes the trigger name as a nested <triggername> element,
                        // not as an attribute on <singletriggerpropertyfilter>.
                        currentSingleTriggerEvent = reader.ReadElementContentAsString();
                    }
                    else if (inSingleTriggerFilter && reader.Name.Equals("name"))
                    {
                        currentSingleTriggerField = reader.ReadElementContentAsString();
                    }
                    else if (inSingleTriggerFilter && reader.Name.Equals("operation"))
                    {
                        currentSingleTriggerOperation = reader.ReadElementContentAsString();
                    }
                    else if (inSingleTriggerFilter && reader.Name.Equals("value"))
                    {
                        currentSingleTriggerValue = reader.ReadElementContentAsString();
                    }
                    else if (reader.Name.Equals("provider"))
                    {
                        if (triggerName != null && !eventProvider.ContainsKey(triggerName))
                        {
                            eventProvider.Add(triggerName, Guid.Parse(reader.ReadElementContentAsString()));
                        }
                    }
                    else if (inScriptFilter && reader.Name.Equals("var"))
                    {
                        if (currentScriptEqualVar == null)
                        {
                            string? varName = reader.GetAttribute("name");
                            if (!string.IsNullOrWhiteSpace(varName))
                            {
                                currentScriptEqualVar = varName;
                            }
                        }
                    }
                    else if (inScriptFilter && reader.Name.Equals("transition"))
                    {
                        string? transitionName = reader.GetAttribute("name");
                        if (!string.IsNullOrWhiteSpace(currentScriptEqualVar) && !string.IsNullOrWhiteSpace(transitionName))
                        {
                            int dot = transitionName.LastIndexOf('.');
                            if (dot >= 0 && dot < transitionName.Length - 1)
                            {
                                string fieldName = transitionName[(dot + 1)..];
                                scriptVarToField[currentScriptEqualVar] = fieldName;
                            }
                        }
                        currentScriptEqualVar = null;
                    }
                    else if (inScriptFilter && reader.Name.Equals("equal"))
                    {
                        currentScriptEqualVar = null;
                    }
                    else if (inScriptFilter && reader.Name.Equals("const"))
                    {
                        string? constValue = reader.GetAttribute("value");
                        if (!string.IsNullOrWhiteSpace(currentScriptEqualVar) && !string.IsNullOrWhiteSpace(constValue))
                        {
                            scriptEquals.Add((currentScriptEqualVar, constValue));
                        }
                    }
                    else if (reader.Name.Equals("state") && validScenario)
                    {
                        stateId = reader.GetAttribute("id");
                    }
                    else if (reader.Name.Equals("transition") && validScenario)
                    {
                        inTransition = true;

                        int targetIndex = -1;
                        int stateIndex = stateId == null ? -1 : (stateId.Equals("_start") ? 0 : Int32.Parse(stateId));
                        string? eventName = reader.GetAttribute("event");
                        string? tempAttr = reader.GetAttribute("target");

                        if (tempAttr != null && !tempAttr.Equals("_cancel"))
                        {
                            targetIndex = tempAttr.Equals("_complete") ? int.MaxValue : Int32.Parse(tempAttr);
                        }

                        pendingTransitionEventName = eventName;
                        pendingTransitionStateIndex = stateIndex;
                        pendingTransitionIsValid = targetIndex != -1;

                        if (reader.IsEmptyElement)
                        {
                            if (pendingTransitionEventName != null
                                && pendingTransitionStateIndex != -1
                                && pendingTransitionIsValid
                                && eventProvider.ContainsKey(pendingTransitionEventName))
                            {
                                states.Add((
                                    new State(
                                        pendingTransitionEventName,
                                        eventProvider[pendingTransitionEventName]),
                                    pendingTransitionStateIndex));
                            }

                            inTransition = false;
                            pendingTransitionEventName = null;
                            pendingTransitionStateIndex = -1;
                            pendingTransitionIsValid = false;
                        }
                    }
                }
                else
                {
                    if (reader.Name.Equals("scenario"))
                    {
                        if (validScenario)
                        {
                            states.Sort((left, right) => left.Index.CompareTo(right.Index));
                            if (states.Count > 0)
                            {
                                scenarios.Add(new PerftrackScenario(
                                    scenarioName!,
                                    ptName,
                                    durationField,
                                    states.Select(entry => entry.State).ToList(),
                                    new List<TriggerCondition>(triggerConditions),
                                    new List<ScriptFilterHint>(scriptFilterHints)));
                            }
                        }
                        else
                        {
                            validScenario = true;
                        }

                        states.Clear();
                        triggerConditions.Clear();
                        scriptFilterHints.Clear();
                        filterApplyTarget = null;
                        currentFilterName = null;
                    }
                    else if (reader.Name.Equals("singletriggerpropertyfilter"))
                    {
                        if (inSingleTriggerFilter
                            && currentFilterName != null
                            && currentSingleTriggerEvent != null
                            && currentSingleTriggerField != null
                            && currentSingleTriggerOperation != null
                            && currentSingleTriggerValue != null)
                        {
                            triggerConditions.Add(new TriggerCondition(
                                currentSingleTriggerField,
                                currentSingleTriggerOperation,
                                currentSingleTriggerValue));
                        }

                        inSingleTriggerFilter = false;
                        currentSingleTriggerEvent = null;
                        currentSingleTriggerField = null;
                        currentSingleTriggerOperation = null;
                        currentSingleTriggerValue = null;
                    }
                    else if (reader.Name.Equals("filter"))
                    {
                        if (inTransition)
                        {
                            inTransition = false;
                        }

                        filterApplyTarget = null;
                        currentFilterName = null;
                    }
                    else if (reader.Name.Equals("scriptfilter"))
                    {
                        if (inScriptFilter
                            && currentFilterName != null)
                        {
                            long? completionKind = null;
                            HashSet<long> testCaseIds = new HashSet<long>();

                            foreach (var equal in scriptEquals)
                            {
                                if (!scriptVarToField.ContainsKey(equal.varName))
                                {
                                    continue;
                                }

                                string field = scriptVarToField[equal.varName];
                                if (!long.TryParse(equal.constValue, out long parsed))
                                {
                                    continue;
                                }

                                if (field.Equals("completionKind", StringComparison.OrdinalIgnoreCase))
                                {
                                    completionKind = parsed;
                                }
                                else if (field.Equals("testCaseId", StringComparison.OrdinalIgnoreCase))
                                {
                                    testCaseIds.Add(parsed);
                                }
                            }

                            if (completionKind.HasValue || testCaseIds.Count > 0)
                            {
                                scriptFilterHints.Add(new ScriptFilterHint(
                                    completionKind,
                                    testCaseIds));
                            }
                        }

                        inScriptFilter = false;
                        scriptVarToField.Clear();
                        scriptEquals.Clear();
                        currentScriptEqualVar = null;
                    }
                    else if (reader.Name.Equals("transition"))
                    {
                        if (inTransition
                            && pendingTransitionEventName != null
                            && pendingTransitionStateIndex != -1
                            && pendingTransitionIsValid
                            && eventProvider.ContainsKey(pendingTransitionEventName))
                        {
                            states.Add((
                                new State(
                                    pendingTransitionEventName,
                                    eventProvider[pendingTransitionEventName]),
                                pendingTransitionStateIndex));
                        }

                        inTransition = false;
                        pendingTransitionEventName = null;
                        pendingTransitionStateIndex = -1;
                        pendingTransitionIsValid = false;
                    }
                }
            }
            return scenarios;
        }
    }
}
