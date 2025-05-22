#ifndef DEBUG_MQH
#define DEBUG_MQH

void LogInfo(string message) {
   if(LogVerbosity >= LOG_VERBOSE) Print(message);
}

void LogImportant(string message) {
   if(LogVerbosity >= LOG_IMPORTANT) Print(message);
}

void LogError(string message) {
   Print("ERROR: ", message); // Always log errors
}

void LogWarning(string message) {
   if(LogVerbosity >= LOG_IMPORTANT) Print("WARNING: ", message);
}

#endif // DEBUG_MQH
