#ifndef __LOG_MQH__
#define __LOG_MQH__

enum ENUM_LOG_LEVEL
{
   LOG_ERRORS_ONLY,
   LOG_IMPORTANT,
   LOG_VERBOSE
};

// LogVerbosity must be defined in including EA (e.g., as input)
extern ENUM_LOG_LEVEL LogVerbosity;

#define LogInfo(...)      if(LogVerbosity >= LOG_VERBOSE)   Print(__VA_ARGS__)
#define LogImportant(...) if(LogVerbosity >= LOG_IMPORTANT) Print(__VA_ARGS__)
#define LogError(...)     Print("ERROR: ", __VA_ARGS__)
#define LogWarning(...)   if(LogVerbosity >= LOG_IMPORTANT) Print("WARNING: ", __VA_ARGS__)

#endif // __LOG_MQH__
