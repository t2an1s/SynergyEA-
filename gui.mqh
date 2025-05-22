#ifndef GUI_MQH
#define GUI_MQH

void CreateDashboard();
void UpdateDashboard();
void DeleteDashboard();

// label helpers
void CreateLabel(string name,string text,int x,int y,color clr,int fontSize=0,string font="Arial",bool centered=false);
void CreateLabel(string name,string txt,int x,int y,color c); // hedge variant

void CreateSectionHeader(string title,int y);
void CreateDataRow(string label,string propValue,string liveValue,int y);
void CreateCostRecoverySection(int y);

void ShowMarketBiasIndicator();
void DrawPivotLines();
string GetHedgeStatusDescription();

#endif // GUI_MQH
