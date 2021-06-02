Set-StrictMode -Version Latest
class AutoCloseBugManager {
    hidden [string] $OrganizationName;
    hidden [PSObject] $ControlSettings;
    static [SVTEventContext []] $ClosedBugs=$null;
    hidden [string] $ScanSource;
    hidden [bool] $UseAzureStorageAccount = $false;
    hidden [BugLogHelper] $BugLogHelperObj;

    AutoCloseBugManager([string] $orgName) {
        $this.OrganizationName = $orgName;
        $this.ControlSettings = [ConfigurationManager]::LoadServerConfigFile("ControlSettings.json");
        $this.ScanSource = [AzSKSettings]::GetInstance().GetScanSource();
        
        if ([Helpers]::CheckMember($this.ControlSettings.BugLogging, "UseAzureStorageAccount", $null)) {
            $this.UseAzureStorageAccount = $this.ControlSettings.BugLogging.UseAzureStorageAccount;
            if ($this.UseAzureStorageAccount) {
                $this.BugLogHelperObj = [BugLogHelper]::BugLogHelperInstance
		        if (!$this.BugLogHelperObj) {
		        	$this.BugLogHelperObj = [BugLogHelper]::GetInstance($this.OrganizationName);
		        }
            }
        }
    }


    #function to auto close resolved bugs
    hidden [void] AutoCloseBug([SVTEventContext []] $ControlResults) {

        #tags that need to be searched
        $TagSearchKeyword = ""
        #flag to check number of current keywords in the tag
        $QueryKeyWordCount = 0;
        #maximum no of keywords that need to be checked per batch
        $MaxKeyWordsToQuery=0;    
        #all passing control results go here
        $PassedControlResults = @();
        $autoCloseOrgBugFlag=$true
        $autoCloseProjBugFlag=$true;
        [AutoCloseBugManager]::ClosedBugs=$null

        

        try {
            $MaxKeyWordsToQuery = $this.ControlSettings.BugLogging.MaxKeyWordsToQueryForBugClose;
            $autoCloseOrgBugFlag=$this.ControlSettings.BugLogging.AutoCloseOrgBug
            $autoCloseProjBugFlag=$this.ControlSettings.BugLogging.AutoCloseProjectBug
        }
        catch {
            $MaxKeyWordsToQuery=30
            $autoCloseOrgBugFlag=$true
            $autoCloseProjBugFlag=$true;
        }

        #collect all passed control results
        $ControlResults | ForEach-Object {
            if ($_.ControlResults[0].VerificationResult -eq "Passed") {
                #to check if org level bugs should be auto closed based on control settings
                if($_.FeatureName -eq "Organization"){
                    if($autoCloseOrgBugFlag -eq $true){
                        $PassedControlResults += $_
                    }
                }
                #to check if proj level bugs should be auto closed based on control settings
                elseif($_.FeatureName -eq "Project"){
                    if($autoCloseProjBugFlag -eq $true){
                        $PassedControlResults += $_
                    }
                }
                else {
                    $PassedControlResults += $_
                }
            }
        }

        #number of passed controls
        $PassedControlResultsLength = ($PassedControlResults | Measure-Object).Count
        $TagToControlIDMap=$null
        $TagToControlIDMap=@{}
        #the following loop will call api for bug closing in batches of size as defined in control settings,
        #first check if passed controls length is less than the batch size, if yes then we have to combine all tags in one go
        #and call the api
        #if length is more divide the control results in chunks of batch size, after a particular batch is made call the api
        #reinitialize the variables for the next batch

        $PassedControlResults | ForEach-Object {
            			
            $control = $_;

            #if control results are less than the maximum no of tags per batch
            if ($PassedControlResultsLength -lt $MaxKeyWordsToQuery) {
                #check for number of tags in current query
                $QueryKeyWordCount++;
                # $this.UseAzureStorageAccount=true;

                if ($this.UseAzureStorageAccount -and $this.ScanSource -eq "CA")
                {
                    #complete the query
                    $tagHash=$this.GetHashedTag($control.ControlItem.Id, $control.ResourceContext.ResourceId)
                    $TagToControlIDMap.add($tagHash,$control);
                    $TagSearchKeyword += "(ADOScannerHashId eq '" + $tagHash + "') or "
                    #if the query count equals the passing control results, search for bugs for this batch
                    if ($QueryKeyWordCount -eq $PassedControlResultsLength) {
                        #to remove OR from the last tag keyword. Ex: Tags: Tag1 OR Tags: Tag2 OR. Remove the last OR from this keyword
                        $TagSearchKeyword = $TagSearchKeyword.Substring(0, $TagSearchKeyword.length - 3)
                        $response = $this.BugLogHelperObj.GetTableEntityAndCloseBug($TagSearchKeyword)
                        # if ($response[0].results.count -gt 0) {
                        #     $response.results | ForEach-Object {
                        #         #Add the closed bug
                        #         $TagToControlIDMap[$_.fields."system.tags"].ControlResults.AddMessage("Closed Bug",$_.url);
                        #         [AutoCloseBugManager]::ClosedBugs+=$TagToControlIDMap[$_.fields."system.tags"]
                        #     }
                        # }
                    }
                }
                else {
                    #complete the query
                    $tagHash= $this.GetHashedTag($control.ControlItem.Id, $control.ResourceContext.ResourceId);
                    $TagToControlIDMap.add($tagHash,$control);
                    $TagSearchKeyword += "Tags: " + $tagHash + " OR "
                    #if the query count equals the passing control results, search for bugs for this batch
                    if ($QueryKeyWordCount -eq $PassedControlResultsLength) {
                        #to remove OR from the last tag keyword. Ex: Tags: Tag1 OR Tags: Tag2 OR. Remove the last OR from this keyword
                        $TagSearchKeyword = $TagSearchKeyword.Substring(0, $TagSearchKeyword.length - 3)
                        $response = $this.GetWorkItemByHash($TagSearchKeyword,$MaxKeyWordsToQuery)
                        #if bug was present
                        if ($response[0].results.count -gt 0) {
                            $response.results | ForEach-Object {
                                #close the bug
                                $id = $_.fields."system.id"
                                $Project = $_.project.name

                                if($this.CloseBug($id, $Project))
                                {
                                $urlClose= "https://dev.azure.com/{0}/{1}/_workitems/edit/{2}" -f $this.OrganizationName, $Project , $id;
                                $TagToControlIDMap[$_.fields."system.tags"].ControlResults.AddMessage("Closed Bug",$urlClose);
                                [AutoCloseBugManager]::ClosedBugs+=$TagToControlIDMap[$_.fields."system.tags"]}
                            }
                        }
                    }
                }
            }
                #if the number of control results was more than batch size
                else {
                    $QueryKeyWordCount++;
                    if ($this.UseAzureStorageAccount -and $this.ScanSource -eq "CA")
                    {
                        $TagSearchKeyword += "(ADOScannerHashId eq '" + $this.GetHashedTag($control.ControlItem.Id, $control.ResourceContext.ResourceId) + "') or "

                        #if number of tags reaches batch limit
                        if ($QueryKeyWordCount -eq $MaxKeyWordsToQuery) {
                            #query for all these tags and their bugs
                            $TagSearchKeyword = $TagSearchKeyword.Substring(0, $TagSearchKeyword.length - 3)
                            $response = $this.BugLogHelperObj.GetTableEntityAndCloseBug($TagSearchKeyword);
                            # if ($response[0].results.count -gt 0) {
                            #     $response.results | ForEach-Object {
                                    #Add the closed bug
                                    # $TagToControlIDMap[$_.fields."system.tags"].ControlResults.AddMessage("Closed Bug",$_.url);
                                    # [AutoCloseBugManager]::ClosedBugs+=$TagToControlIDMap[$_.fields."system.tags"]
                                # }
                            # }
                            #Reinitialize for the next batch
                            $QueryKeyWordCount = 0;
                            $TagSearchKeyword = "";
                            $PassedControlResultsLength -= $MaxKeyWordsToQuery
                        }
                    }
                    else
                    {
                        $tagHash= $this.GetHashedTag($control.ControlItem.Id, $control.ResourceContext.ResourceId)
                        $TagToControlIDMap.add($tagHash,$control);
                        $TagSearchKeyword += "Tags: " + $tagHash + " OR "
                        #if number of tags reaches batch limit
                        if ($QueryKeyWordCount -eq $MaxKeyWordsToQuery) {
                        #query for all these tags and their bugs
                        $TagSearchKeyword = $TagSearchKeyword.Substring(0, $TagSearchKeyword.length - 3)
                        $response = $this.GetWorkItemByHash($TagSearchKeyword,$MaxKeyWordsToQuery)
                        if ($response[0].results.count -gt 0) {
                            $response.results | ForEach-Object {
                                $id = $_.fields."system.id"
                                $Project = $_.project.name
                                if($this.CloseBug($id, $Project)){
                                $urlClose= "https://dev.azure.com/{0}/{1}/_workitems/edit/{2}" -f $this.OrganizationName, $Project , $id;
                                $TagToControlIDMap[$_.fields."system.tags"].ControlResults.AddMessage("Closed Bug",$urlClose);
                                [AutoCloseBugManager]::ClosedBugs+=$TagToControlIDMap[$_.fields."system.tags"]
                           }}
                        }
                        #Reinitialize for the next batch
                        $QueryKeyWordCount = 0;
                        $TagSearchKeyword = "";
                        $PassedControlResultsLength -= $MaxKeyWordsToQuery
                        }
                    }
                }
                
            }
        $TagToControlIDMap.Clear();
        Remove-Variable $TagToControlIDMap;

        
        
    
    }

    #function to close an active bug
    hidden [Bool] CloseBug([string] $id, [string] $Project) {
        $url = "https://dev.azure.com/{0}/{1}/_apis/wit/workitems/{2}?api-version=6.0" -f $this.OrganizationName, $Project, $id
        
        #load the closed bug template
        $BugTemplate = [ConfigurationManager]::LoadServerConfigFile("TemplateForClosedBug.Json")
        $BugTemplate = $BugTemplate | ConvertTo-Json -Depth 10

           
           
        $header = [WebRequestHelper]::GetAuthHeaderFromUriPatch($url)
                
        try {
            $responseObj = Invoke-RestMethod -Uri $url -Method Patch  -ContentType "application/json-patch+json ; charset=utf-8" -Headers $header -Body $BugTemplate
            return $true

        }
        catch {
            Write-Host "Could not close the bug" -ForegroundColor Red
            return $false
        }
    }

    #function to retrieve all new/active/resolved bugs 
    hidden [object] GetWorkItemByHash([string] $hash,[int] $MaxKeyWordsToQuery) 
    {
        $url = "https://almsearch.dev.azure.com/{0}/_apis/search/workitemsearchresults?api-version=6.0-preview.1" -f $this.OrganizationName
        #take results have been doubled, as their might be chances for a bug to be logged more than once, if the tag id is copied.
        #in this case we want all the instances of this bug to be closed
        $body = '{"searchText": "{0}","$skip": 0,"$top": 60,"filters": {"System.TeamProject": [],"System.WorkItemType": ["Bug"],"System.State": ["New","Active","Resolved"]}}'| ConvertFrom-Json
        $body.searchText = $hash
        $response = [WebRequestHelper]:: InvokePostWebRequest($url, $body)
        return  $response
    }

    #function to create hash for bug tag
    hidden [string] GetHashedTag([string] $ControlId, [string] $ResourceId) {
        $hashedTag = $null
        $stringToHash = "$ResourceId#$ControlId";
        #return the bug tag
        if ($this.UseAzureStorageAccount -and $this.ScanSource -eq "CA") 
        {
            return [AutoBugLog]::ComputeHashX($stringToHash);
        }
        else {
            return "ADOScanID: " + [AutoBugLog]::ComputeHashX($stringToHash)
        }
    }



}
