/// CallMinimization holds an immutable snapshot for this call's task scope alone.
public enum CallMinimization {
    @TaskLocal public static var current: ValueMinimization?
}
