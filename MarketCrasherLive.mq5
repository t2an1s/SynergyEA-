diff --git a//dev/null b/MarketCrasherLive.mq5
index 0000000..7c0c303 100644
--- a//dev/null
+++ b/MarketCrasherLive.mq5
@@ -0,0 +1,23 @@
+//+------------------------------------------------------------------+
+//|                                                     MarketCrasherLive.mq5 |
+//|                        Hedge bridge EA                            |
+//+------------------------------------------------------------------+
+#property copyright ""
+#property link      ""
+#property version   "1.00"
+#property strict
+
+int OnInit()
+  {
+   return(INIT_SUCCEEDED);
+  }
+
+void OnDeinit(const int reason)
+  {
+  }
+
+void OnTick()
+  {
+   // hedge management will be implemented here
+  }
+//+------------------------------------------------------------------+
