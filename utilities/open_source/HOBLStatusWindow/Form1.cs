using System.ComponentModel;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;

namespace HOBLStatusWindow;

public partial class Form1 : Form
{
    private const int ScreenMargin = 16;
    private const int TextColumns = 50;
    private const int TextRows = 3;
    private const int WsExNoActivate = 0x08000000;
    private const uint SwpNoSize = 0x0001;
    private const uint SwpNoMove = 0x0002;
    private const uint SwpNoActivate = 0x0010;

    private static readonly nint HwndTopmost = new(-1);
    private static readonly string WidthMeasurementText = new('M', TextColumns);
    private static readonly Regex ColorTag = new(
        @"\[(?:(?<close>/)color|color=(?<color>[A-Za-z]+|#[0-9A-Fa-f]{6}))\]",
        RegexOptions.Compiled | RegexOptions.IgnoreCase);

    private readonly CancellationTokenSource cancellation = new();
    private readonly string messagePipeName;

    public Form1(string message, string messagePipeName)
    {
        InitializeComponent();
        RenderMessage(message);
        this.messagePipeName = messagePipeName;
        _ = ListenForMessagesAsync();
    }

    protected override bool ShowWithoutActivation => true;

    protected override CreateParams CreateParams
    {
        get
        {
            CreateParams parameters = base.CreateParams;
            parameters.ExStyle |= WsExNoActivate;
            return parameters;
        }
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);

        SizeWindowForText();
        PositionWindow();
        ReassertTopMost();
    }

    protected override void OnDpiChanged(DpiChangedEventArgs e)
    {
        base.OnDpiChanged(e);
        SizeWindowForText();
        PositionWindow();
        ReassertTopMost();
    }

    private void SizeWindowForText()
    {
        Size measuredText = TextRenderer.MeasureText(
            WidthMeasurementText,
            messageBox.Font,
            Size.Empty,
            TextFormatFlags.NoPadding | TextFormatFlags.SingleLine);
        int contentWidth = measuredText.Width;
        int contentHeight = messageBox.Font.Height * TextRows;

        ClientSize = new Size(
            contentWidth + (messageBox.Left * 2),
            contentHeight + (messageBox.Top * 2));
    }

    private void PositionWindow()
    {
        Rectangle workingArea = Screen.PrimaryScreen?.WorkingArea
            ?? SystemInformation.VirtualScreen;
        Location = new Point(
            workingArea.Right - Width - ScreenMargin,
            workingArea.Bottom - Height - ScreenMargin);
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        cancellation.Cancel();
        cancellation.Dispose();
        base.OnFormClosed(e);
    }

    private async Task ListenForMessagesAsync()
    {
        while (!cancellation.IsCancellationRequested)
        {
            using NamedPipeServerStream server = new(
                messagePipeName,
                PipeDirection.In,
                1,
                PipeTransmissionMode.Byte,
                PipeOptions.Asynchronous);

            try
            {
                await server.WaitForConnectionAsync(cancellation.Token);
                using StreamReader reader = new(server);
                string message = await reader.ReadToEndAsync(cancellation.Token);

                if (!string.IsNullOrWhiteSpace(message) && !IsDisposed)
                {
                    BeginInvoke(() => RenderMessage(message));
                }
            }
            catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
            {
                return;
            }
            catch (IOException exception)
            {
                if (!cancellation.IsCancellationRequested)
                {
                    BeginInvoke(() => RenderMessage(
                        $"[color=Red] ERROR - Status message pipe failed: {exception.Message}[/color]"));
                }

                return;
            }
        }
    }

    private void RenderMessage(string markup)
    {
        messageBox.Clear();

        try
        {
            RenderColorMarkup(markup);
        }
        catch (ArgumentException exception)
        {
            messageBox.Clear();
            AppendText($" ERROR - {exception.Message}", Color.Red);
        }

        messageBox.SelectionStart = 0;
        messageBox.ScrollToCaret();

        if (IsHandleCreated)
        {
            ReassertTopMost();
        }
    }

    private void RenderColorMarkup(string markup)
    {
        Stack<Color> colors = new();
        colors.Push(Color.White);
        int currentPosition = 0;

        foreach (Match match in ColorTag.Matches(markup))
        {
            AppendText(markup[currentPosition..match.Index], colors.Peek());

            if (match.Groups["close"].Success)
            {
                if (colors.Count == 1)
                {
                    throw new ArgumentException("Unexpected closing color tag.");
                }

                colors.Pop();
            }
            else
            {
                colors.Push(ParseColor(match.Groups["color"].Value));
            }

            currentPosition = match.Index + match.Length;
        }

        if (colors.Count != 1)
        {
            throw new ArgumentException("A color tag is missing its closing [/color] tag.");
        }

        AppendText(markup[currentPosition..], colors.Peek());
    }

    private void AppendText(string text, Color color)
    {
        messageBox.SelectionStart = messageBox.TextLength;
        messageBox.SelectionColor = color;
        messageBox.AppendText(text);
    }

    private static Color ParseColor(string value)
    {
        if (value.StartsWith('#'))
        {
            return ColorTranslator.FromHtml(value);
        }

        Color color = Color.FromName(value);
        if (!color.IsKnownColor && !color.IsSystemColor)
        {
            throw new ArgumentException($"Unknown color '{value}'.");
        }

        return color;
    }

    private void ReassertTopMost()
    {
        if (!SetWindowPos(
                Handle,
                HwndTopmost,
                0,
                0,
                0,
                0,
                SwpNoMove | SwpNoSize | SwpNoActivate))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowPos(
        nint windowHandle,
        nint insertAfter,
        int x,
        int y,
        int width,
        int height,
        uint flags);
}
