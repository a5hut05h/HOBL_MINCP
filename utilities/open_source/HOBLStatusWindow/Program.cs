using System.IO.Pipes;

namespace HOBLStatusWindow;

static class Program
{
    private const string InstanceMutexName = @"Local\HoblStatusWindow.Instance";
    private const string MessagePipeName = "HoblStatusWindow.Message";

    [STAThread]
    static void Main(string[] args)
    {
        ApplicationConfiguration.Initialize();
        string message = args.Length > 0
            ? string.Join(' ', args)
            : "No status message supplied.";

        using Mutex instanceMutex = new(true, InstanceMutexName, out bool isFirstInstance);
        if (!isFirstInstance)
        {
            SendMessageToExistingInstance(message);
            return;
        }

        Application.Run(new Form1(message, MessagePipeName));
    }

    private static void SendMessageToExistingInstance(string message)
    {
        try
        {
            using NamedPipeClientStream client = new(
                ".",
                MessagePipeName,
                PipeDirection.Out);
            client.Connect(500);

            using StreamWriter writer = new(client);
            writer.Write(message);
        }
        catch (TimeoutException)
        {
            MessageBox.Show(
                " ERROR - The existing status window did not accept the message.",
                "Status Window",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        }
        catch (IOException exception)
        {
            MessageBox.Show(
                $" ERROR - Unable to send the status message: {exception.Message}",
                "Status Window",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        }
    }
}