#!/bin/bash\n\necho \
Testing
smart
suggestions
with
debug
mode...\\n\ncurl -X POST \http://localhost:3000/api/openai/smart-suggestions-shared?debug=true\ \\\n  -H \Content-Type:
application/json\ \\\n  -d '{\dailyLog\:{\date\:\2023-05-01\,\foodEntries\:[],\exerciseEntries\:[],\summary\:{\totalCaloriesConsumed\:0,\totalCaloriesBurned\:0,\macros\:{\carbs\:0,\protein\:0,\fat\:0},\micronutrients\:{}}},\userProfile\:{\weight\:70,\height\:170,\age\:30,\gender\:\male\,\activityLevel\:\moderate\,\goal\:\maintain\},\recentLogs\:[],\aiConfig\:{\agentModel\:{\source\:\shared\}}}'\n
