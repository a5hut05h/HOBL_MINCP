using System.Globalization;
using System.Text;
using System.Xml.Linq;
using Microsoft.Diagnostics.Tracing;
using Microsoft.Diagnostics.Tracing.Etlx;

if (!TryParseArguments(args, out Options options))
{
    PrintUsage();
    return 1;
}

try
{
    IReadOnlyList<RegionDefinition> definitions = LoadDefinitions(options.ManifestPath);
    IReadOnlyList<Iteration> iterations = ParseIterations(options.EtlPath, definitions);
    WriteIterations(options.OutputPath, iterations);

    Console.WriteLine(
        $"Loaded {definitions.Count:N0} region definitions and wrote " +
        $"{iterations.Count:N0} iterations to: {options.OutputPath}");
    return 0;
}
catch (Exception ex)
{
    Console.Error.WriteLine(ex.Message);
    return 1;
}

static IReadOnlyList<RegionDefinition> LoadDefinitions(string manifestPath)
{
    XDocument document = XDocument.Load(manifestPath, LoadOptions.SetLineInfo);
    var definitions = new List<RegionDefinition>();

    foreach (XElement regionElement in document.Descendants("Region"))
    {
        XElement? startElement = regionElement.Element("Start");
        XElement? stopElement = regionElement.Element("Stop");
        string? friendlyName = (string?)regionElement.Attribute("FriendlyName");

        if (startElement is null || stopElement is null || string.IsNullOrWhiteSpace(friendlyName))
        {
            continue;
        }

        if (!TryParseEventPattern(startElement, friendlyName, "Start", out EventPattern start)
            || !TryParseEventPattern(stopElement, friendlyName, "Stop", out EventPattern stop))
        {
            continue;
        }

        XElement? matchEvent = regionElement.Element("Match")?.Element("Event");

        definitions.Add(new RegionDefinition(
            definitions.Count,
            friendlyName,
            start,
            stop,
            IsTrue(matchEvent?.Attribute("PID")),
            IsTrue(matchEvent?.Attribute("TID")),
            matchEvent?.Elements("Payload")
                .Select(payload => (string?)payload.Attribute("FieldName"))
                .Where(name => !string.IsNullOrWhiteSpace(name))
                .Cast<string>()
                .ToArray() ?? []));
    }

    if (definitions.Count == 0)
    {
        throw new InvalidDataException(
            $"No start/stop region definitions were found in '{manifestPath}'.");
    }

    return definitions;
}

static bool TryParseEventPattern(
    XElement endpointElement,
    string regionName,
    string endpointName,
    out EventPattern pattern)
{
    pattern = null!;
    XElement? eventElement = endpointElement.Element("Event");
    string? providerText = (string?)eventElement?.Attribute("Provider");
    string? eventIdText = (string?)eventElement?.Attribute("Id");

    if (!Guid.TryParse(providerText, out Guid provider)
        || !int.TryParse(eventIdText, NumberStyles.Integer, CultureInfo.InvariantCulture,
            out int eventId))
    {
        return false;
    }

    PayloadCondition[] conditions = endpointElement.Elements("PayloadIdentifier")
        .Select(identifier =>
        {
            string fieldName = (string?)identifier.Attribute("FieldName")
                ?? throw new InvalidDataException(
                    $"{regionName} has a {endpointName} payload identifier without FieldName.");
            string fieldValue = (string?)identifier.Attribute("FieldValue")
                ?? throw new InvalidDataException(
                    $"{regionName} has a {endpointName} payload identifier without FieldValue.");

            return new PayloadCondition(fieldName, NormalizeLiteral(fieldValue));
        })
        .ToArray();

    pattern = new EventPattern(provider, eventId, conditions);
    return true;
}

static IReadOnlyList<Iteration> ParseIterations(
    string etlPath,
    IReadOnlyList<RegionDefinition> definitions)
{
    EndpointIndex index = BuildEndpointIndex(definitions);
    var active = new Dictionary<RegionInstanceKey, Stack<ActiveStart>>();
    var completed = new List<Iteration>();
    string? latestInputInjectName = null;

    using var source = new ETWTraceEventSource(etlPath);
    source.Dynamic.All += data =>
    {
        if (TryGetInputInjectName(data, out string inputInjectName))
        {
            if (!string.Equals(inputInjectName, "transactionend", StringComparison.OrdinalIgnoreCase))
            {
                latestInputInjectName = inputInjectName;
            }

            return;
        }

        foreach (Endpoint endpoint in index.Find(data))
        {
            if (!Matches(data, endpoint.Pattern)
                || !TryCreateInstanceKey(data, endpoint.Definition, out RegionInstanceKey key))
            {
                continue;
            }

            if (endpoint.Kind == EndpointKind.Start)
            {
                PushStart(active, key, ToSeconds(data), latestInputInjectName);
            }
            else if (endpoint.Kind == EndpointKind.Stop)
            {
                CompleteIteration(active, completed, key, endpoint.Definition, data);
            }
            else if (active.TryGetValue(key, out Stack<ActiveStart>? starts)
                     && starts.Count > 0)
            {
                CompleteIteration(active, completed, key, endpoint.Definition, data);
            }
            else
            {
                PushStart(active, key, ToSeconds(data), latestInputInjectName);
            }
        }
    };

    source.Process();
    return MergeOverlappingIterations(completed);
}

static IReadOnlyList<Iteration> MergeOverlappingIterations(
    IReadOnlyList<Iteration> iterations)
{
    var merged = new List<Iteration>();

    foreach (IGrouping<string, Iteration> eventGroup in
             iterations.GroupBy(iteration => iteration.EventName, StringComparer.Ordinal))
    {
        Iteration? current = null;
        foreach (Iteration iteration in eventGroup.OrderBy(item => item.StartSeconds))
        {
            if (current is null)
            {
                current = iteration;
                continue;
            }

            if (iteration.StartSeconds <= current.EndSeconds)
            {
                if (iteration.EndSeconds > current.EndSeconds)
                {
                    double endSeconds = iteration.EndSeconds;
                    current = current with
                    {
                        DurationMilliseconds =
                            (endSeconds - current.StartSeconds) * 1000.0,
                        EndSeconds = endSeconds
                    };
                }

                continue;
            }

            merged.Add(current);
            current = iteration;
        }

        if (current is not null)
        {
            merged.Add(current);
        }
    }

    return merged.OrderBy(iteration => iteration.StartSeconds).ToArray();
}

static EndpointIndex BuildEndpointIndex(IReadOnlyList<RegionDefinition> definitions)
{
    var index = new EndpointIndex();
    foreach (RegionDefinition definition in definitions)
    {
        if (PatternsEqual(definition.Start, definition.Stop))
        {
            index.Add(new Endpoint(definition, definition.Start, EndpointKind.Toggle));
        }
        else
        {
            index.Add(new Endpoint(definition, definition.Start, EndpointKind.Start));
            index.Add(new Endpoint(definition, definition.Stop, EndpointKind.Stop));
        }
    }

    return index;
}

static void PushStart(
    Dictionary<RegionInstanceKey, Stack<ActiveStart>> active,
    RegionInstanceKey key,
    double startSeconds,
    string? inputInjectName)
{
    if (!active.TryGetValue(key, out Stack<ActiveStart>? starts))
    {
        starts = new Stack<ActiveStart>();
        active.Add(key, starts);
    }

    starts.Push(new ActiveStart(startSeconds, inputInjectName));
}

static void CompleteIteration(
    Dictionary<RegionInstanceKey, Stack<ActiveStart>> active,
    List<Iteration> completed,
    RegionInstanceKey key,
    RegionDefinition definition,
    TraceEvent data)
{
    if (!active.TryGetValue(key, out Stack<ActiveStart>? starts) || starts.Count == 0)
    {
        return;
    }

    ActiveStart start = starts.Pop();
    double durationMilliseconds = data.TimeStampRelativeMSec - start.StartSeconds * 1000.0;
    string eventName = string.IsNullOrWhiteSpace(start.InputInjectName)
        ? definition.FriendlyName
        : $"{start.InputInjectName}_{definition.FriendlyName}";
    completed.Add(new Iteration(
        eventName,
        durationMilliseconds,
        start.StartSeconds,
        ToSeconds(data)));
}

static bool TryGetInputInjectName(TraceEvent data, out string name)
{
    name = string.Empty;
    if (data.ProviderGuid != new Guid("150a3791-7792-452d-858c-15d647ecb48f"))
    {
        return false;
    }

    if (TryGetPayload(data, "tag", out string tag) && !string.IsNullOrWhiteSpace(tag))
    {
        name = tag;
    }
    else if (!string.IsNullOrWhiteSpace(data.TaskName))
    {
        name = data.TaskName;
    }
    else
    {
        name = "InputInject";
    }

    return true;
}

static bool PatternsEqual(EventPattern left, EventPattern right) =>
    left.Provider == right.Provider
    && left.EventId == right.EventId
    && left.Conditions.SequenceEqual(right.Conditions);

static bool Matches(TraceEvent data, EventPattern pattern)
{
    if (data.ProviderGuid != pattern.Provider || (int)data.ID != pattern.EventId)
    {
        return false;
    }

    foreach (PayloadCondition condition in pattern.Conditions)
    {
        if (!TryGetPayload(data, condition.FieldName, out string value)
            || !string.Equals(value, condition.Value, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }
    }

    return true;
}

static bool TryCreateInstanceKey(
    TraceEvent data,
    RegionDefinition definition,
    out RegionInstanceKey key)
{
    var matchValues = new string[definition.MatchPayloadFields.Count];
    for (int index = 0; index < definition.MatchPayloadFields.Count; index++)
    {
        if (!TryGetPayload(data, definition.MatchPayloadFields[index], out string value))
        {
            key = default;
            return false;
        }

        matchValues[index] = value;
    }

    key = new RegionInstanceKey(
        definition.Id,
        definition.MatchProcessId ? data.ProcessID : null,
        definition.MatchThreadId ? data.ThreadID : null,
        string.Join("\u001f", matchValues));
    return true;
}

static bool TryGetPayload(TraceEvent data, string fieldName, out string value)
{
    value = string.Empty;
    if (!data.PayloadNames.Contains(fieldName, StringComparer.Ordinal))
    {
        return false;
    }

    value = PayloadNormalizer.Normalize(data.PayloadByName(fieldName));
    return true;
}

static string NormalizeLiteral(string value)
{
    value = value.Trim();
    if (value.StartsWith("0x", StringComparison.OrdinalIgnoreCase)
        && ulong.TryParse(value[2..], NumberStyles.HexNumber, CultureInfo.InvariantCulture,
            out ulong hexValue))
    {
        return hexValue.ToString(CultureInfo.InvariantCulture);
    }

    return value;
}

static void WriteIterations(string outputPath, IReadOnlyList<Iteration> iterations)
{
    using var writer = new StreamWriter(outputPath, true, new UTF8Encoding(true));

    foreach (Iteration iteration in iterations)
    {
        writer.WriteLine(string.Join(",",
            Csv($"PerfCodeMarker_{iteration.EventName}"),
            DurationNumber(iteration.DurationMilliseconds)));
    }
}

static bool TryParseArguments(string[] args, out Options options)
{
    options = null!;
    if (args.Length < 1)
    {
        return false;
    }

    string etlPath = Path.GetFullPath(args[0]);
    string? manifestPath = FindDefaultManifest(etlPath);
    string outputPath = Path.ChangeExtension(etlPath, ".iterations.csv");

    for (int index = 1; index < args.Length; index++)
    {
        if (string.Equals(args[index], "--manifest", StringComparison.OrdinalIgnoreCase)
            && index + 1 < args.Length)
        {
            manifestPath = Path.GetFullPath(args[++index]);
        }
        else if (string.Equals(args[index], "--output", StringComparison.OrdinalIgnoreCase)
                 && index + 1 < args.Length)
        {
            outputPath = Path.GetFullPath(args[++index]);
        }
        else
        {
            Console.Error.WriteLine($"Invalid argument: {args[index]}");
            return false;
        }
    }

    if (!File.Exists(etlPath))
    {
        Console.Error.WriteLine($"ETL file not found: {etlPath}");
        return false;
    }

    if (manifestPath is null || !File.Exists(manifestPath))
    {
        Console.Error.WriteLine(
            "Regions manifest not found. Specify it with --manifest <regions.xml>.");
        return false;
    }

    options = new Options(etlPath, manifestPath, Path.GetFullPath(outputPath));
    return true;
}

static string? FindDefaultManifest(string etlPath)
{
    string etlDirectory = Path.GetDirectoryName(etlPath) ?? Environment.CurrentDirectory;
    string[] candidates =
    [
        Path.Combine(etlDirectory, "OfficeCodeMarkers.regions.xml"),
        Path.Combine(
            etlDirectory,
            "..",
            "Office-Performance-MSO-Scripts",
            "src",
            "WPAP",
            "OfficeCodeMarkers.regions.xml")
    ];

    return candidates.Select(Path.GetFullPath).FirstOrDefault(File.Exists);
}

static bool IsTrue(XAttribute? attribute) =>
    bool.TryParse(attribute?.Value, out bool value) && value;

static double ToSeconds(TraceEvent data) => data.TimeStampRelativeMSec / 1000.0;

static string DurationNumber(double value) =>
    value.ToString("F6", CultureInfo.InvariantCulture);

static string Csv(string value) => $"\"{value.Replace("\"", "\"\"")}\"";

static void PrintUsage()
{
    Console.Error.WriteLine(
        """
        Usage:
                    cmparser <trace.etl>
              [--manifest <regions.xml>]
              [--output <output.csv>]

        The CSV contains Event Name and Duration (ms).
        """);
}

internal sealed class EndpointIndex
{
    private readonly Dictionary<EventKey, List<Endpoint>> _withoutConditions = [];
    private readonly Dictionary<ConditionKey, List<Endpoint>> _byFirstCondition = [];

    internal void Add(Endpoint endpoint)
    {
        EventPattern pattern = endpoint.Pattern;
        if (pattern.Conditions.Count == 0)
        {
            AddTo(_withoutConditions, new EventKey(pattern.Provider, pattern.EventId), endpoint);
            return;
        }

        PayloadCondition first = pattern.Conditions[0];
        AddTo(
            _byFirstCondition,
            new ConditionKey(
                pattern.Provider,
                pattern.EventId,
                first.FieldName,
                first.Value),
            endpoint);
    }

    internal IEnumerable<Endpoint> Find(TraceEvent data)
    {
        var eventKey = new EventKey(data.ProviderGuid, (int)data.ID);
        if (_withoutConditions.TryGetValue(eventKey, out List<Endpoint>? unconditional))
        {
            foreach (Endpoint endpoint in unconditional)
            {
                yield return endpoint;
            }
        }

        foreach (string payloadName in data.PayloadNames)
        {
            string payloadValue = PayloadNormalizer.Normalize(data.PayloadByName(payloadName));
            var conditionKey =
                new ConditionKey(data.ProviderGuid, (int)data.ID, payloadName, payloadValue);

            if (_byFirstCondition.TryGetValue(conditionKey, out List<Endpoint>? endpoints))
            {
                foreach (Endpoint endpoint in endpoints)
                {
                    yield return endpoint;
                }
            }
        }
    }

    private static void AddTo<TKey>(
        Dictionary<TKey, List<Endpoint>> dictionary,
        TKey key,
        Endpoint endpoint)
        where TKey : notnull
    {
        if (!dictionary.TryGetValue(key, out List<Endpoint>? endpoints))
        {
            endpoints = [];
            dictionary.Add(key, endpoints);
        }

        endpoints.Add(endpoint);
    }
}

internal sealed record Options(string EtlPath, string ManifestPath, string OutputPath);

internal sealed record RegionDefinition(
    int Id,
    string FriendlyName,
    EventPattern Start,
    EventPattern Stop,
    bool MatchProcessId,
    bool MatchThreadId,
    IReadOnlyList<string> MatchPayloadFields);

internal sealed record EventPattern(
    Guid Provider,
    int EventId,
    IReadOnlyList<PayloadCondition> Conditions);

internal sealed record PayloadCondition(string FieldName, string Value);

internal sealed record Endpoint(
    RegionDefinition Definition,
    EventPattern Pattern,
    EndpointKind Kind);

internal enum EndpointKind
{
    Start,
    Stop,
    Toggle
}

internal readonly record struct EventKey(Guid Provider, int EventId);

internal readonly record struct ConditionKey(
    Guid Provider,
    int EventId,
    string FieldName,
    string FieldValue);

internal readonly record struct RegionInstanceKey(
    int DefinitionId,
    int? ProcessId,
    int? ThreadId,
    string MatchPayloadValues);

internal readonly record struct ActiveStart(double StartSeconds, string? InputInjectName);

internal sealed record Iteration(
    string EventName,
    double DurationMilliseconds,
    double StartSeconds,
    double EndSeconds);

internal static class PayloadNormalizer
{
    internal static string Normalize(object? value) => value switch
    {
        null => string.Empty,
        byte number => number.ToString(CultureInfo.InvariantCulture),
        sbyte number => number.ToString(CultureInfo.InvariantCulture),
        short number => number.ToString(CultureInfo.InvariantCulture),
        ushort number => number.ToString(CultureInfo.InvariantCulture),
        int number => number.ToString(CultureInfo.InvariantCulture),
        uint number => number.ToString(CultureInfo.InvariantCulture),
        long number => number.ToString(CultureInfo.InvariantCulture),
        ulong number => number.ToString(CultureInfo.InvariantCulture),
        _ => Convert.ToString(value, CultureInfo.InvariantCulture) ?? string.Empty
    };
}
