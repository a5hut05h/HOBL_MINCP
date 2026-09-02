// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

using Newtonsoft.Json;
using Newtonsoft.Json.Linq;


namespace InputInject
{
    public class InputItem
    {
        public string? tag;
        public string cmd = string.Empty;
        public List<string>? x;
        public List<string>? y;
        public List<string>? delay;
        public string? keys;
        public string? perf;
        public bool primary;
        public string? direction;
        public string? fileName;
        public string? traceId = "";
        public int traceX = 0;
        public int traceY = 0;
        public int traceW = 10;
        public int traceH = 10;
        public int traceMs = 1000;
        public int traceFramerate = 60;
    }

    public class Program
    {
        static void Main(string[] args)
        {
            Application p = new Application();
            if (args.Length == 0)
            {
                Console.WriteLine("Usage: InputInject <json file path or json string>");
                return;
            }
            p.Process(args[0]);

            //Stopwatch stopWatch = new Stopwatch();
            //stopWatch.Start();
            //for (int i = 0; i < 60; i++)
            //{
            //    p.Screenshot();
            //}
            //stopWatch.Stop();
            //TimeSpan ts = stopWatch.Elapsed;
            //string elapsedTime = String.Format("{0:00}:{1:00}:{2:00}.{3:00}", ts.Hours, ts.Minutes, ts.Seconds, ts.Milliseconds / 10);
            //Console.WriteLine("RunTime: " + elapsedTime);

            // p.Screenshot(0, 0, 1, 1);
        }
    }

    public class Application
    {
        public QOIEncoder Encoder;
        Interop interop;

        public Application()
        {
            Encoder = new QOIEncoder();
            interop = new Interop(this);
        }

        public byte[] Screenshot(double xFrac, double yFrac, double wFrac, double hFrac, Int64 screenIndex = 0)
        {
            byte[] image = interop.Screenshot(xFrac, yFrac, wFrac, hFrac, screenIndex);
            return(image);
        }

        public int ContinuousScreenshot(Int64 x, Int64 y, Int64 w, Int64 h, string outputDir ,Int64 screenIndex = 0, Int64 time_ms = 10000, Int64 framerate = 60)
        {
            int count = interop.ContinuousScreenshot( x, y, w, h, outputDir, screenIndex, time_ms, framerate);
            return(count);
        }

        public void WriteCapturesToDisk(string outputDir)
        {
            interop.WriteCapturesToDisk(outputDir);
        }

        public void StopCapture()
        {
            interop.StopCapture();
        }

        public Int64 GetScreenWidth()
        {
            return (interop.GetScreenWidth());
        }

        public Int64 GetScreenHeight()
        {
            return (interop.GetScreenHeight());
        }

        public string GetScreenInfo()
        {
            return (interop.GetScreenInfo());
        }

        public void MoveTo(Int64 x, Int64 y, Int64 screenIndex = 0, bool moveCursor = false)
        {
            interop.MoveTo(x, y, screenIndex, moveCursor);
        }

        public void MoveBy(Int64 x, Int64 y, bool moveCursor = false)
        {
            interop.MoveBy(x, y, moveCursor);
        }

        public void Tap(Int64 x, Int64 y, Int64 delay, bool primary, Int64 screenIndex = 0, bool moveCursor = false, string traceId = "", Int64 traceX = 0, Int64 traceY = 0, Int64 traceW = 10, Int64 traceH = 10, Int64 traceMs = 1000, Int64 traceFramerate = 60)
        {
            interop.Tap(x, y, delay, primary, screenIndex, moveCursor);

            // Record screen if traceId is provided
            if (!string.IsNullOrEmpty(traceId))
            {
                interop.ContinuousScreenshot(traceX, traceY, traceW, traceH, traceId, time_ms: traceMs, framerate: traceFramerate);
            }

        }

        public void TapDown(Int64 x, Int64 y, bool primary, Int64 screenIndex = 0, bool moveCursor = false)
        {
            interop.TapDown(x, y, primary, screenIndex, moveCursor);
        }

        public void TapUp(Int64 x, Int64 y, bool primary, Int64 screenIndex = 0, bool moveCursor = false)
        {
            interop.TapUp(x, y, primary, screenIndex, moveCursor);
        }

        // public void Path(List<Int64> x_list, List<Int64> y_list, List<Int64> delay_list, bool primary, Int64 screenIndex = 0)
        public void Path(JArray x_list, JArray y_list, JArray delay_list, bool primary, Int64 screenIndex = 0)
        {
            if (x_list.Count != y_list.Count || x_list.Count != delay_list.Count)
            {
                throw new InvalidOperationException("x, y, and delay lists must have the same length.");
            }
            int x = x_list != null && x_list.Count > 0 ? (int)x_list[0] : throw new InvalidOperationException("item.x is null or empty");
            int y = y_list != null && y_list.Count > 0 ? (int)y_list[0] : throw new InvalidOperationException("item.y is null or empty");
            int delay = delay_list != null && delay_list.Count > 0 ? (int)delay_list[0] : throw new InvalidOperationException("item.delay is null or empty");
            MoveTo(x, y, screenIndex, moveCursor: false);
            TouchDown();
            Thread.Sleep(delay);
            for (int i = 1; i < x_list.Count; i++)
            {
                x = (int)x_list[i];
                y = (int)y_list[i];
                delay = (int)delay_list[i];
                MoveTo(x, y, screenIndex, moveCursor: false);
                Thread.Sleep(delay);
            }
            TouchUp();
        }

        public void Scroll(Int64 x, Int64 y, Int64 delay, string direction, Int64 screenIndex = 0, bool moveCursor = false, string traceId = "", Int64 traceX = 0, Int64 traceY = 0, Int64 traceW = 10, Int64 traceH = 10, Int64 traceMs = 1000, Int64 traceFramerate = 60)
        {
            interop.Scroll(x, y, delay, direction, screenIndex, moveCursor);
            
            // Record screen if traceId is provided
            if (!string.IsNullOrEmpty(traceId))
            {
                interop.ContinuousScreenshot(traceX, traceY, traceW, traceH, traceId, time_ms: traceMs, framerate: traceFramerate);
            }
        }

        public void Type(string s, Int64 delay, string traceId = "", Int64 traceX = 0, Int64 traceY = 0, Int64 traceW = 10, Int64 traceH = 10, Int64 traceMs = 1000, Int64 traceFramerate = 60)
        {
            interop.Type(s, delay);

            // Record screen if traceId is provided
            if (!string.IsNullOrEmpty(traceId))
            {
                interop.ContinuousScreenshot(traceX, traceY, traceW, traceH, traceId, time_ms: traceMs, framerate: traceFramerate);
            }
        }

        public void WindowMove(Int64 delay, Int64 screenIndex = 0)
        {
            interop.WindowMove(delay, screenIndex);
        }

        public void WindowMaximize()
        {
            interop.WindowMaximize();
        }

        public void Process(string args)
        {
            DateTime startTime = DateTime.Now;
            if (args.Length == 0)
            {
                System.Environment.Exit(-1);
            }
            string jsonFile = args;

            string json;
            string perfMode = "0";

            if (File.Exists(jsonFile))
            {
                // If the supplied arguments is the path to a file, then read the file.
                json = File.ReadAllText(jsonFile);
            }
            else
            {
                // Else, assume the supplied argument is a json string itself to be parsed.
                json = jsonFile;
            }

            var inputList = JsonConvert.DeserializeObject<List<InputItem>>(json);
            if (inputList == null)
            {
                throw new InvalidOperationException("Deserialization resulted in a null input list.");
            }

            foreach (InputItem item in inputList)
            {
                if (perfMode == "1" && item.perf == "0")
                {
                    continue;
                }

                if (item.cmd == "tap")
                {
                    if (item.x != null && item.y != null && item.delay != null)
                    {
                        Tap(Int64.Parse(item.x[0]), Int64.Parse(item.y[0]), Int64.Parse(item.delay[0]), item.primary, traceId: item.traceId, traceX: item.traceX, traceY: item.traceY, traceW: item.traceW, traceH: item.traceH, traceMs: item.traceMs, traceFramerate: item.traceFramerate);
                    }
                }

                if (item.cmd == "moveby")
                {
                    int x = item.x != null ? Int32.Parse(item.x[0]) : throw new InvalidOperationException("item.x is null");
                    int y = item.y != null ? Int32.Parse(item.y[0]) : throw new InvalidOperationException("item.y is null");
                    int delay = item.delay != null ? Int32.Parse(item.delay[0]) : throw new InvalidOperationException("item.delay is null");
                    MoveBy(x, y);
                    Thread.Sleep(delay);
                }

                if (item.cmd == "moveto")
                {
                    int x = item.x != null && item.x.Count > 0 ? Int32.Parse(item.x[0]) : throw new InvalidOperationException("item.x is null or empty");
                    int y = item.y != null && item.y.Count > 0 ? Int32.Parse(item.y[0]) : throw new InvalidOperationException("item.y is null or empty");
                    int delay = item.delay != null && item.delay.Count > 0 ? Int32.Parse(item.delay[0]) : throw new InvalidOperationException("item.delay is null or empty");
                    MoveTo(x, y);
                    Thread.Sleep(delay);
                }

                else if (item.cmd == "scroll")
                {
                    int x = item.x != null && item.x.Count > 0 ? Int32.Parse(item.x[0]) : throw new InvalidOperationException("item.x is null or empty");
                    int y = item.y != null && item.y.Count > 0 ? Int32.Parse(item.y[0]) : throw new InvalidOperationException("item.y is null or empty");
                    int delay = item.delay != null && item.delay.Count > 0 ? Int32.Parse(item.delay[0]) : throw new InvalidOperationException("item.delay is null or empty");
                    string direction = item.direction != null ? item.direction : throw new InvalidOperationException("item.direction is null or empty");

                    Scroll(Int64.Parse(item.x[0]), Int64.Parse(item.y[0]), Int64.Parse(item.delay[0]), item.direction);
                }

                else if (item.cmd == "type")
                {
                    if (item.keys != null)
                    {
                        if (item.delay != null && item.delay.Count > 0)
                        {
                            Type(item.keys, Int32.Parse(item.delay[0]), traceId:item.traceId, traceX:item.traceX, traceY:item.traceY, traceW:item.traceW, traceH:item.traceH, traceMs:item.traceMs, traceFramerate:item.traceFramerate);
                        }
                        else
                        {
                            throw new InvalidOperationException("item.delay is null or empty");
                        }
                    }
                    else
                    {
                        throw new InvalidOperationException("item.keys is null");
                    }
                }

                else if (item.cmd == "windowmove")
                {
                    if (item.delay != null && item.delay.Count > 0 && item.direction != null)
                    {
                        WindowMove(Int32.Parse(item.delay[0]), Int32.Parse(item.direction));
                    }
                }

                // Deprecated:
                //else if (item.cmd == "datetime")
                //{
                //    int delay = Int32.Parse(item.delay[0]);
                //    string pattern = DateTime.Now.ToString(item.keys);
                //    string sendString = "";
                //    foreach (char c in pattern)
                //    {
                //        sendString += c;
                //        SendKeys.SendWait(sendString);
                //        sendString = "";
                //        Thread.Sleep(delay);
                //    }
                //}

                // Deprecated:
                // else if (item.cmd == "snapwindow")
                // {
                //     //const int KEYEVENTF_EXTENDEDKEY = 0x1;
                //     //const int KEYEVENTF_KEYUP = 0x2;

                //     keybd_event(0x5B, 0x45, KEYEVENTF_EXTENDEDKEY, 0); // Win down
                //     Thread.Sleep(200);
                //     keybd_event(0x25, 0x45, KEYEVENTF_EXTENDEDKEY, 0); // Left down
                //     keybd_event(0x25, 0x45, KEYEVENTF_EXTENDEDKEY | KEYEVENTF_KEYUP, 0); // Left up
                //     Thread.Sleep(200);
                //     keybd_event(0x26, 0x45, KEYEVENTF_EXTENDEDKEY, 0); // Up down
                //     keybd_event(0x26, 0x45, KEYEVENTF_EXTENDEDKEY | KEYEVENTF_KEYUP, 0); // Up up
                //     Thread.Sleep(200);
                //     keybd_event(0x5B, 0x45, KEYEVENTF_EXTENDEDKEY | KEYEVENTF_KEYUP, 0); // Win up
                // }

                else if (item.cmd == "path")
                {
                    int x = item.x != null && item.x.Count > 0 ? Int32.Parse(item.x[0]) : throw new InvalidOperationException("item.x is null or empty");
                    int y = item.y != null && item.y.Count > 0 ? Int32.Parse(item.y[0]) : throw new InvalidOperationException("item.y is null or empty");
                    int delay = item.delay != null && item.delay.Count > 0 ? Int32.Parse(item.delay[0]) : throw new InvalidOperationException("item.delay is null or empty");
                    MoveTo(x, y);
                    TouchDown();
                    Thread.Sleep(delay);
                    for (int i = 1; i < item.x.Count; i++)
                    {
                        x = Int32.Parse(item.x[i]);
                        y = Int32.Parse(item.y[i]);
                        delay = Int32.Parse(item.delay[i]);
                        MoveTo(x, y);
                        Thread.Sleep(delay);
                    }
                    TouchUp();
                }

                else if (item.cmd == "sleep")
                {
                    int delay = item.delay != null && item.delay.Count > 0 ? Int32.Parse(item.delay[0]) : throw new InvalidOperationException("item.delay is null or empty");
                    Thread.Sleep(delay);
                }

                else if (item.cmd == "sleepto")
                {
                    DateTime now = DateTime.Now;
                    TimeSpan span = now.Subtract(startTime);
                    int delayTilNow = (int)(span.TotalSeconds * 1000);
                    int target = item.delay != null && item.delay.Count > 0 ? Int32.Parse(item.delay[0]) : throw new InvalidOperationException("item.delay is null or empty");
                    int delay = target - delayTilNow;
                    if (delay > 0)
                    {
                        Thread.Sleep(delay);
                    }
                }

                else if (item.cmd == "etw")
                {
                    if (item.tag != null)
                    {
                        EventTag(item.tag);
                    }
                    else
                    {
                        throw new InvalidOperationException("item.tag is null");
                    }
                }

                else if (item.cmd == "screenshot")
                {
                    // Not supported in HOBL 25+
                    // using (Bitmap screenshot = takingScreenshot())
                    // {
                    //     string folderName = new FileInfo(item.fileName).DirectoryName;
                    //     if (!Directory.Exists(folderName))
                    //     {
                    //         Directory.CreateDirectory(folderName);
                    //     }
                    //     screenshot.Save(item.fileName, ImageFormat.Png);
                    // }
                }
            }
        }

        public void EventTag(string tag)
        {
            interop.EventTag(tag);
        }   

        public void sleepTo(DateTime startTime, long targetDelay)
        {
            DateTime now = DateTime.Now;
            TimeSpan span = now.Subtract(startTime);
            long delayTilNow = (long)(span.TotalSeconds * 1000);
            long delay = targetDelay - delayTilNow;
            if (delay > 0)
            {
                Thread.Sleep((int)delay);
            }
        }

        // Legacy screenshot method
        // Bitmap takingScreenshot()
        // {
        //     //Create a new bitmap.
        //     var bmpScreenshot = new Bitmap(ScreenWidth, ScreenHeight);

        //     // Create a graphics object from the bitmap.
        //     var g = Graphics.FromImage(bmpScreenshot);
        //     Size ImageSize = new Size(ScreenWidth, ScreenHeight);

        //     // Take the screenshot from the upper left corner to the right bottom corner.
        //     g.CopyFromScreen(0,
        //                      0,
        //                      0,
        //                      0,
        //                      ImageSize);

        //     return bmpScreenshot;
        // }

        public void TouchDown(bool primary = true)
        {
            interop.TouchDown(primary);
        }

        public void TouchUp(bool primary = true)
        {
            interop.TouchUp(primary);
        }

        public void MouseWheel(int delay)
        {
            interop.MouseWheel(delay);
        }
    }
}
