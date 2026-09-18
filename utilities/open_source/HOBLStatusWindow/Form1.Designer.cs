namespace HOBLStatusWindow;

partial class Form1
{
    /// <summary>
    ///  Required designer variable.
    /// </summary>
    private System.ComponentModel.IContainer components = null;

    /// <summary>
    ///  Clean up any resources being used.
    /// </summary>
    /// <param name="disposing">true if managed resources should be disposed; otherwise, false.</param>
    protected override void Dispose(bool disposing)
    {
        if (disposing && (components != null))
        {
            components.Dispose();
        }
        base.Dispose(disposing);
    }

    #region Windows Form Designer generated code

    /// <summary>
    ///  Required method for Designer support - do not modify
    ///  the contents of this method with the code editor.
    /// </summary>
    private void InitializeComponent()
    {
        messageBox = new RichTextBox();
        SuspendLayout();
        // 
        // messageBox
        // 
        messageBox.Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right;
        messageBox.BackColor = Color.Black;
        messageBox.BorderStyle = BorderStyle.None;
        messageBox.DetectUrls = false;
        messageBox.Font = new Font("Consolas", 12F);
        messageBox.ForeColor = Color.White;
        messageBox.Location = new Point(16, 16);
        messageBox.Name = "messageBox";
        messageBox.ReadOnly = true;
        messageBox.ScrollBars = RichTextBoxScrollBars.Vertical;
        messageBox.Size = new Size(598, 108);
        messageBox.TabIndex = 0;
        messageBox.TabStop = false;
        messageBox.Text = "";
        // 
        // Form1
        // 
        AutoScaleMode = AutoScaleMode.Dpi;
        BackColor = Color.Black;
        ClientSize = new Size(630, 140);
        Controls.Add(messageBox);
        FormBorderStyle = FormBorderStyle.FixedToolWindow;
        MaximizeBox = false;
        MinimizeBox = false;
        Name = "Form1";
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        Text = "HOBL Status";
        TopMost = true;
        ResumeLayout(false);
    }

    #endregion

    private RichTextBox messageBox;
}
