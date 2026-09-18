using System.Drawing;

namespace InputInject;

public static class MousePathGenerator
{
    public static Point[] Generate(Point start, Point end, int pointCount)
    {
        if (pointCount < 2)
        {
            throw new ArgumentOutOfRangeException(
                nameof(pointCount),
                "At least two points are required.");
        }

        Point[] points = GC.AllocateUninitializedArray<Point>(pointCount);
        points[0] = start;
        points[^1] = end;

        double deltaX = end.X - start.X;
        double deltaY = end.Y - start.Y;
        double denominator = pointCount - 1;

        for (int index = 1; index < pointCount - 1; index++)
        {
            double progress = index / denominator;
            double easedProgress = progress * progress * (3.0 - (2.0 * progress));

            points[index] = new Point(
                start.X + (int)Math.Round(deltaX * easedProgress),
                start.Y + (int)Math.Round(deltaY * easedProgress));
        }

        return points;
    }
}
