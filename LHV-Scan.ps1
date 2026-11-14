# =============================================================================
#  LHV Scan - the window
# =============================================================================
#
#  WHAT THIS TOOL IS FOR
#    It makes a list of the airport sceneries and aircraft in your flight
#    simulator, shows you that list, lets you correct it, and then sends it
#    to your "My sim" page at LH Virtual - or saves it as a file.
#    LH Virtual uses the list to plan flights with aircraft you own, to
#    airports where you have scenery.
#
#  WHAT YOU SEE IS WHAT HAPPENS
#    Step 1  Find      which simulators are on this PC, and which folders
#    Step 2  Scan      every add-on folder is read; the window shows which one
#    Step 3  Check     the result list; unclear add-ons can be corrected
#    Step 4  Send      only when you press the button
#
#  WHAT THIS TOOL NEVER DOES
#    - It never changes, moves or deletes anything in your simulator.
#    - It never sends anything before you press "Send to My sim".
#    - It never sends folder paths, your user name or anything about your PC.
#      "Show what is sent" displays the exact text, every time.
#
#  THE ONLY INTERNET ADDRESS THIS TOOL EVER CONTACTS
#    the one at the top of scan-send.ps1, and only for "Send to My sim".
#
#  THE ONLY FILES THIS TOOL EVER WRITES
#    - the result file, where YOU choose to save it ("Save as file")
#    - your corrections:  %APPDATA%\LHV-Scan\fixes.json
#
#  THREE FILES, ONE JOB EACH (all in this folder)
#    scan-engine.ps1   reads your simulator          (never uses the internet)
#    scan-send.ps1     sends the list                (the only internet use)
#    LHV-Scan.ps1      this file: the window         (shows, asks, calls the two)
#  You can open all three with Notepad. Lines starting with # explain.
# =============================================================================

param(
    # Shows the window with a small made-up list instead of scanning.
    # Good for a first look, and it works on a PC without a simulator.
    [switch]$Demo,
    # For the documentation: draw the window once, save it as a picture, close.
    [string]$Screenshot = '',
    # For developers: send to a test server instead of LH Virtual.
    [string]$UploadUrl = ''
)

$ErrorActionPreference = 'Stop'

# Load the reading and the sending functions from the files next to this one.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'scan-engine.ps1')
. (Join-Path $here 'scan-send.ps1')
if ($UploadUrl) { $script:LhvUploadUrl = $UploadUrl }

# The parts of Windows that draw windows (WPF). They are part of Windows.
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

# -----------------------------------------------------------------------------
#  What the tool remembers while the window is open.
# -----------------------------------------------------------------------------
$script:Simulators = @()      # from Get-LhvSimulators
$script:Entries    = @()      # the scan result (see New-LhvEntry in scan-engine.ps1)
$script:Fixes      = @{}      # your corrections, "sim|folder" -> fix
$script:Filter     = 'all'    # which tab of the result list is shown
$script:Sent       = $false   # was the list sent or saved in this session?

# =============================================================================
#  THE WINDOW (layout only - no logic in here)
#  Colours and shapes follow the LH Virtual dashboard: navy header, one yellow
#  button for the next step, corners of 8 / 6 / 4 pixels.
# =============================================================================
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="LHV Scan" Width="1120" Height="760" MinWidth="940" MinHeight="620"
        Background="#F4F6FA" FontFamily="Segoe UI" FontSize="13" WindowStartupLocation="CenterScreen">
  <Window.Resources>
    <SolidColorBrush x:Key="Navy" Color="#05164D"/>
    <SolidColorBrush x:Key="Ink" Color="#00235F"/>
    <SolidColorBrush x:Key="Muted" Color="#5B6B8C"/>
    <SolidColorBrush x:Key="Line" Color="#D5DDEA"/>
    <SolidColorBrush x:Key="Yellow" Color="#FFAD00"/>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="#00235F"/>
      <Setter Property="Background" Value="White"/>
      <Setter Property="BorderBrush" Value="#D5DDEA"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="14,8"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1.5" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="#00235F"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#FFAD00"/>
      <Setter Property="BorderBrush" Value="#FFAD00"/>
      <Setter Property="Foreground" Value="#05164D"/>
    </Style>
    <Style x:Key="Tab" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#5B6B8C"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,4,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="b" Background="Transparent" BorderBrush="Transparent" BorderThickness="1" CornerRadius="6" Padding="11,6">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="b" Property="Background" Value="#00235F"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="White"/>
      <Setter Property="BorderBrush" Value="#D5DDEA"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="8"/>
    </Style>
    <Style x:Key="Cat" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#5B6B8C"/>
      <Setter Property="FontSize" Value="10.5"/>
      <Setter Property="FontWeight" Value="Bold"/>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- Header -->
    <Border Grid.Row="0" Background="{StaticResource Navy}" Padding="24,14">
      <Grid>
        <StackPanel>
          <TextBlock Text="LH VIRTUAL" Foreground="#B9C4E0" FontSize="10.5" FontWeight="Bold"/>
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="LHV Scan" Foreground="White" FontSize="22" FontWeight="Bold"/>
            <TextBlock x:Name="VersionText" Foreground="#B9C4E0" FontSize="12" Margin="10,9,0,0"/>
          </StackPanel>
        </StackPanel>
        <TextBlock Text="Reads only. Nothing in your simulator is changed." Foreground="#DCE3F5"
                   HorizontalAlignment="Right" VerticalAlignment="Center"/>
      </Grid>
    </Border>

    <!-- The four steps: green = done, yellow = next, grey = later -->
    <Border Grid.Row="1" Margin="24,16,24,0" Style="{StaticResource Card}">
      <UniformGrid Columns="4" x:Name="Steps"/>
    </Border>

    <!-- Body -->
    <Grid Grid.Row="2" Margin="24,16,24,16">
      <Grid.ColumnDefinitions><ColumnDefinition Width="300"/><ColumnDefinition Width="16"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>

      <!-- Left: what is scanned -->
      <Border Grid.Column="0" Style="{StaticResource Card}" Padding="18">
        <DockPanel>
          <TextBlock DockPanel.Dock="Top" Text="What is scanned" Foreground="{StaticResource Ink}" FontSize="16" FontWeight="Bold"/>
          <TextBlock DockPanel.Dock="Top" x:Name="FoundText" Foreground="{StaticResource Muted}" TextWrapping="Wrap" Margin="0,4,0,10"/>
          <StackPanel DockPanel.Dock="Bottom">
            <Button x:Name="ScanButton" Content="Scan now" Style="{StaticResource BtnPrimary}" Padding="14,11" FontSize="14"/>
            <ProgressBar x:Name="Progress" Height="6" Margin="0,10,0,0" Minimum="0" Maximum="100" Foreground="#FFAD00" Background="#E8ECF4" BorderThickness="0" Visibility="Collapsed"/>
            <TextBlock x:Name="ProgressText" Foreground="{StaticResource Muted}" FontSize="12" TextTrimming="CharacterEllipsis" Margin="0,6,0,0" Height="34" TextWrapping="Wrap"/>
            <Button x:Name="AddFolderButton" Content="Add another add-on folder..." Style="{StaticResource Btn}" Margin="0,4,0,0"/>
            <TextBlock Foreground="{StaticResource Muted}" FontSize="11.5" TextWrapping="Wrap" Margin="0,10,0,0"
                       Text="Folder paths stay on this PC. Only the result list is sent, and only when you press Send."/>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="SimList"/></ScrollViewer>
        </DockPanel>
      </Border>

      <!-- Right: what was found -->
      <Border Grid.Column="2" Style="{StaticResource Card}">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>

          <UniformGrid Grid.Row="0" Columns="5" x:Name="Tiles"/>

          <Border Grid.Row="1" BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,1" Padding="14,9" Background="#F8FAFD">
            <DockPanel>
              <TextBox x:Name="SearchBox" DockPanel.Dock="Right" Width="170" Padding="7,5" BorderBrush="{StaticResource Line}" ToolTip="Search by name or code"/>
              <TextBlock DockPanel.Dock="Right" Text="Search" Foreground="{StaticResource Muted}" VerticalAlignment="Center" Margin="0,0,8,0"/>
              <StackPanel Orientation="Horizontal">
                <RadioButton x:Name="TabAll" Content="All" Style="{StaticResource Tab}" GroupName="f" IsChecked="True"/>
                <RadioButton x:Name="TabAirports" Content="Airports" Style="{StaticResource Tab}" GroupName="f"/>
                <RadioButton x:Name="TabAircraft" Content="Aircraft" Style="{StaticResource Tab}" GroupName="f"/>
                <RadioButton x:Name="TabMods" Content="Mods and more" Style="{StaticResource Tab}" GroupName="f"/>
                <RadioButton x:Name="TabLook" Content="Needs a look" Style="{StaticResource Tab}" GroupName="f"/>
              </StackPanel>
            </DockPanel>
          </Border>

          <Grid Grid.Row="2">
            <DataGrid x:Name="Grid" AutoGenerateColumns="False" IsReadOnly="True" HeadersVisibility="Column" SelectionMode="Single"
                      GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="#EDF1F7" BorderThickness="0" Background="White"
                      RowHeight="30" CanUserResizeRows="False">
              <DataGrid.ColumnHeaderStyle>
                <Style TargetType="DataGridColumnHeader">
                  <Setter Property="Background" Value="White"/><Setter Property="Foreground" Value="#5B6B8C"/>
                  <Setter Property="FontSize" Value="10.5"/><Setter Property="FontWeight" Value="Bold"/>
                  <Setter Property="Padding" Value="10,8"/><Setter Property="BorderBrush" Value="#D5DDEA"/><Setter Property="BorderThickness" Value="0,0,0,1"/>
                </Style>
              </DataGrid.ColumnHeaderStyle>
              <DataGrid.CellStyle>
                <Style TargetType="DataGridCell">
                  <Setter Property="BorderThickness" Value="0"/><Setter Property="Padding" Value="10,0"/>
                  <Setter Property="Background" Value="Transparent"/>
                  <Setter Property="Template">
                    <Setter.Value>
                      <ControlTemplate TargetType="DataGridCell">
                        <Border Padding="{TemplateBinding Padding}" Background="{TemplateBinding Background}">
                          <ContentPresenter VerticalAlignment="Center"/>
                        </Border>
                      </ControlTemplate>
                    </Setter.Value>
                  </Setter>
                  <Style.Triggers>
                    <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#E3EAFA"/><Setter Property="Foreground" Value="#00235F"/></Trigger>
                  </Style.Triggers>
                </Style>
              </DataGrid.CellStyle>
              <DataGrid.RowStyle>
                <Style TargetType="DataGridRow">
                  <Setter Property="Background" Value="White"/>
                  <Style.Triggers>
                    <DataTrigger Binding="{Binding State}" Value="look"><Setter Property="Background" Value="#FFF4D6"/></DataTrigger>
                  </Style.Triggers>
                </Style>
              </DataGrid.RowStyle>
              <DataGrid.Columns>
                <DataGridTextColumn Header="STATUS" Binding="{Binding Status}" Width="104"/>
                <DataGridTextColumn Header="KIND" Binding="{Binding Kind}" Width="84"/>
                <DataGridTextColumn Header="ADD-ON" Binding="{Binding Name}" Width="2*"/>
                <DataGridTextColumn Header="FOUND INSIDE" Binding="{Binding Found}" Width="2*"/>
                <DataGridTextColumn Header="SIMULATOR" Binding="{Binding Sim}" Width="96"/>
              </DataGrid.Columns>
            </DataGrid>
            <TextBlock x:Name="EmptyText" Text="Press &quot;Scan now&quot;. The list of your add-ons appears here."
                       Foreground="{StaticResource Muted}" HorizontalAlignment="Center" VerticalAlignment="Center" FontSize="14"/>
          </Grid>

          <!-- Quick fix for the selected add-on -->
          <Border Grid.Row="3" x:Name="FixPanel" BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0" Padding="16,12" Background="#F8FAFD" Visibility="Collapsed">
            <StackPanel>
              <DockPanel>
                <TextBlock DockPanel.Dock="Left" Text="QUICK FIX" Style="{StaticResource Cat}" VerticalAlignment="Center"/>
                <TextBlock x:Name="FixName" Foreground="{StaticResource Ink}" FontWeight="Bold" Margin="10,0,0,0" TextTrimming="CharacterEllipsis"/>
              </DockPanel>
              <TextBlock x:Name="FixNote" Foreground="{StaticResource Muted}" TextWrapping="Wrap" Margin="0,4,0,8"/>
              <WrapPanel>
                <TextBlock Text="This is" VerticalAlignment="Center" Margin="0,0,8,0"/>
                <ComboBox x:Name="FixKind" Width="236" Padding="7,5">
                  <ComboBoxItem Content="an airport scenery" Tag="airport"/>
                  <ComboBoxItem Content="an aircraft I can fly" Tag="aircraft"/>
                  <ComboBoxItem Content="a mod, library or other (not counted)" Tag="mod"/>
                </ComboBox>
                <TextBlock x:Name="FixCodeLabel" Text="ICAO code" VerticalAlignment="Center" Margin="14,0,8,0"/>
                <TextBox x:Name="FixCodes" Width="130" Padding="7,5" BorderBrush="{StaticResource Line}" CharacterCasing="Upper" ToolTip="For example EDDF. Several codes: separate them with a comma."/>
                <Button x:Name="FixApply" Content="Apply" Style="{StaticResource BtnPrimary}" Margin="12,0,0,0"/>
                <Button x:Name="FixUndo" Content="Undo my fix" Style="{StaticResource Btn}" Margin="8,0,0,0"/>
              </WrapPanel>
              <TextBlock x:Name="FixError" Foreground="#B3261E" Margin="0,6,0,0" Visibility="Collapsed"/>
            </StackPanel>
          </Border>
        </Grid>
      </Border>
    </Grid>

    <!-- Footer: send or save -->
    <Border Grid.Row="3" Background="White" BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0" Padding="24,12">
      <DockPanel>
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
          <Button x:Name="ShowButton" Content="Show what is sent" Style="{StaticResource Btn}" Margin="0,0,8,0"/>
          <Button x:Name="SaveButton" Content="Save as file..." Style="{StaticResource Btn}"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal">
          <StackPanel VerticalAlignment="Center" Margin="0,0,12,0">
            <TextBlock Text="CODE FROM MY SIM" Style="{StaticResource Cat}"/>
            <TextBox x:Name="CodeBox" Width="150" Padding="8,6" Margin="0,3,0,0" FontSize="15" FontWeight="SemiBold" CharacterCasing="Upper"
                     BorderBrush="{StaticResource Line}" ToolTip="Open My sim at LH Virtual, press 'Connect the scan tool' and type the code here."/>
          </StackPanel>
          <Button x:Name="SendButton" Content="Send to My sim" Style="{StaticResource BtnPrimary}" VerticalAlignment="Bottom" Padding="16,9"/>
          <TextBlock x:Name="StatusText" VerticalAlignment="Bottom" Margin="14,0,0,9" Foreground="{StaticResource Muted}" TextWrapping="Wrap" MaxWidth="430"/>
        </StackPanel>
      </DockPanel>
    </Border>
  </Grid>
</Window>
'@

$script:Window = [Windows.Markup.XamlReader]::Parse($xaml)

# -----------------------------------------------------------------------------
#  Find-LhvControl
#  Returns one named part of the window (a button, a text ...), by its name.
# -----------------------------------------------------------------------------
function Find-LhvControl([string]$name) { return $script:Window.FindName($name) }

# Short names for the parts that are used often.
$ui = @{}
foreach ($n in 'VersionText','Steps','FoundText','SimList','ScanButton','Progress','ProgressText','AddFolderButton','Tiles',
               'SearchBox','TabAll','TabAirports','TabAircraft','TabMods','TabLook','Grid','EmptyText','FixPanel','FixName',
               'FixNote','FixKind','FixCodeLabel','FixCodes','FixApply','FixUndo','FixError','ShowButton','SaveButton',
               'CodeBox','SendButton','StatusText') { $ui[$n] = Find-LhvControl $n }
$ui.VersionText.Text = "version $($script:LhvScanVersion)"

# -----------------------------------------------------------------------------
#  New-LhvBrush / Update-LhvWindow - two small helpers.
# -----------------------------------------------------------------------------
function New-LhvBrush([string]$hex) { return (New-Object Windows.Media.BrushConverter).ConvertFromString($hex) }

# Lets the window redraw while a long job (the scan) is running.
function Update-LhvWindow {
    $script:Window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Background)
}

# =============================================================================
#  THE FOUR STEPS AT THE TOP
# =============================================================================

# -----------------------------------------------------------------------------
#  Show-LhvSteps
#  Draws the four steps. $now is the number of the step that is next (1-4);
#  everything before it is green ("done"), everything after it is grey.
#  $now = 5 means: all four are done.
# -----------------------------------------------------------------------------
function Show-LhvSteps([int]$now, [string[]]$texts) {
    $labels = @('Find simulators', 'Scan add-ons', 'Check the list', 'Send to My sim')
    $ui.Steps.Children.Clear()
    for ($i = 1; $i -le 4; $i++) {
        $state = 'later'; if ($i -lt $now) { $state = 'done' } elseif ($i -eq $now) { $state = 'now' }
        $back = 'White'; $dot = '#FFFFFF'; $dotLine = '#C8D2E3'; $ink = '#5B6B8C'; $sub = '#5B6B8C'; $mark = "$i"
        if ($state -eq 'done') { $back = '#E7F4EC'; $dot = '#0A7D3C'; $dotLine = '#0A7D3C'; $ink = '#0A7D3C'; $sub = '#0A7D3C'; $mark = [string][char]0x2713 }
        if ($state -eq 'now')  { $back = '#FFEFC9'; $dot = '#FFAD00'; $dotLine = '#FFAD00'; $ink = '#00235F'; $sub = '#1F2A44' }

        $cell = New-Object Windows.Controls.Border
        $cell.Background = New-LhvBrush $back; $cell.Padding = '14,9'
        if ($i -gt 1) { $cell.BorderBrush = New-LhvBrush '#D5DDEA'; $cell.BorderThickness = '1,0,0,0' }
        $row = New-Object Windows.Controls.StackPanel; $row.Orientation = 'Horizontal'

        $circle = New-Object Windows.Controls.Border
        $circle.Width = 24; $circle.Height = 24; $circle.CornerRadius = 12
        $circle.Background = New-LhvBrush $dot; $circle.BorderBrush = New-LhvBrush $dotLine; $circle.BorderThickness = 1.5
        $num = New-Object Windows.Controls.TextBlock
        $num.Text = $mark; $num.FontWeight = 'Bold'; $num.FontSize = 12
        $num.HorizontalAlignment = 'Center'; $num.VerticalAlignment = 'Center'
        $numInk = '#5B6B8C'; if ($state -eq 'done') { $numInk = '#FFFFFF' } elseif ($state -eq 'now') { $numInk = '#05164D' }
        $num.Foreground = New-LhvBrush $numInk
        $circle.Child = $num

        $text = New-Object Windows.Controls.StackPanel; $text.Margin = '10,0,0,0'
        $a = New-Object Windows.Controls.TextBlock; $a.Text = $labels[$i - 1]; $a.FontWeight = 'Bold'; $a.Foreground = New-LhvBrush $ink
        $b = New-Object Windows.Controls.TextBlock; $b.FontSize = 11.5; $b.Foreground = New-LhvBrush $sub
        $b.Text = ''; if ($texts -and $texts.Count -ge $i) { $b.Text = $texts[$i - 1] }
        if (-not $b.Text) { if ($state -eq 'done') { $b.Text = 'Done' } elseif ($state -eq 'now') { $b.Text = 'Next step' } }
        if ($state -eq 'now') { $b.FontWeight = 'SemiBold' }
        [void]$text.Children.Add($a); [void]$text.Children.Add($b)
        [void]$row.Children.Add($circle); [void]$row.Children.Add($text)
        $cell.Child = $row
        [void]$ui.Steps.Children.Add($cell)
    }
}

# =============================================================================
#  LEFT SIDE: WHICH SIMULATORS AND FOLDERS
# =============================================================================

# -----------------------------------------------------------------------------
#  Show-LhvSimulators
#  Lists the simulators that were found, each with a tick box and the folders
#  that will be read. Un-tick a simulator to leave it out of the scan.
# -----------------------------------------------------------------------------
function Show-LhvSimulators {
    $ui.SimList.Children.Clear()
    foreach ($sim in $script:Simulators) {
        $box = New-Object Windows.Controls.CheckBox
        $box.Content = $sim.name; $box.IsChecked = $true; $box.FontWeight = 'Bold'
        $box.Foreground = New-LhvBrush '#00235F'; $box.Margin = '0,8,0,2'; $box.Tag = $sim
        [void]$ui.SimList.Children.Add($box)
        foreach ($place in $sim.places) {
            $line = New-Object Windows.Controls.TextBlock
            $line.Text = $place.path; $line.ToolTip = $place.path
            $line.Foreground = New-LhvBrush '#5B6B8C'; $line.FontSize = 11.5
            $line.TextTrimming = 'CharacterEllipsis'; $line.Margin = '20,1,0,0'
            [void]$ui.SimList.Children.Add($line)
        }
    }
    $count = @($script:Simulators).Count
    if ($count -eq 0) {
        $ui.FoundText.Text = 'No simulator was found on this PC. You can add an add-on folder yourself.'
    } elseif ($count -eq 1) {
        $ui.FoundText.Text = 'One simulator was found. These folders will be read:'
    } else {
        $ui.FoundText.Text = "$count simulators were found. These folders will be read:"
    }
    $ui.ScanButton.IsEnabled = ($count -gt 0)
}

# -----------------------------------------------------------------------------
#  Get-LhvChosenSimulators
#  The simulators whose box is ticked.
# -----------------------------------------------------------------------------
function Get-LhvChosenSimulators {
    $chosen = @()
    foreach ($child in $ui.SimList.Children) {
        if ($child -is [Windows.Controls.CheckBox] -and $child.IsChecked) { $chosen += $child.Tag }
    }
    return $chosen
}

# =============================================================================
#  RIGHT SIDE: THE RESULT LIST
# =============================================================================

# How each kind is called in the list.
$script:KindNames = @{ airport = 'Airport'; aircraft = 'Aircraft'; livery = 'Livery'; mod = 'Mod'; library = 'Library'
                       traffic = 'AI traffic'; navdata = 'Nav data'; tool = 'Tool'; other = 'Other' }

# -----------------------------------------------------------------------------
#  Get-LhvFoundText
#  The text in the "FOUND INSIDE" column of one add-on.
# -----------------------------------------------------------------------------
function Get-LhvFoundText($entry) {
    if ($entry.kind -eq 'airport') {
        $codes = @($entry.icaos)
        if ($codes.Count -eq 0) { return 'no airport code yet' }
        $text = ($codes | Select-Object -First 6) -join ', '
        if ($codes.Count -gt 6) { $text += " and $($codes.Count - 6) more" }
        return $text
    }
    if ($entry.kind -eq 'aircraft') {
        if (@($entry.aircraftTypes).Count -eq 0) { return 'type not named in its files' }
        return (@($entry.aircraftTypes) -join ', ')
    }
    return "$($entry.detail)"
}

# -----------------------------------------------------------------------------
#  Get-LhvCounted
#  What LH Virtual will use from the list: the airport codes and aircraft
#  types of all add-ons that are clear (read from the files, or fixed by you).
#  Output: @{ airports = <codes>; aircraft = <types> }
# -----------------------------------------------------------------------------
function Get-LhvCounted {
    $airports = New-Object System.Collections.Generic.HashSet[string]
    $aircraft = New-Object System.Collections.Generic.HashSet[string]
    foreach ($e in $script:Entries) {
        if (-not $e.certain) { continue }
        if ($e.kind -eq 'airport')  { foreach ($c in $e.icaos)         { [void]$airports.Add($c) } }
        if ($e.kind -eq 'aircraft') { foreach ($t in $e.aircraftTypes) { [void]$aircraft.Add($t) } }
    }
    return @{ airports = @($airports); aircraft = @($aircraft) }
}

# -----------------------------------------------------------------------------
#  Show-LhvTiles
#  The five numbers above the list.
# -----------------------------------------------------------------------------
function Show-LhvTiles {
    $all = @($script:Entries)
    $look = @($all | Where-Object { -not $_.certain }).Count
    $tiles = @(
        @{ label = 'AIRPORTS';      value = @($all | Where-Object { $_.kind -eq 'airport'  -and $_.certain }).Count },
        @{ label = 'AIRCRAFT';      value = @($all | Where-Object { $_.kind -eq 'aircraft' -and $_.certain }).Count },
        @{ label = 'LIVERIES';      value = @($all | Where-Object { $_.kind -eq 'livery' }).Count },
        @{ label = 'MODS AND MORE'; value = @($all | Where-Object { $_.kind -notin 'airport','aircraft','livery' -and $_.certain }).Count },
        @{ label = 'NEEDS A LOOK';  value = $look; warn = ($look -gt 0) }
    )
    $ui.Tiles.Children.Clear()
    $first = $true
    foreach ($tile in $tiles) {
        $cell = New-Object Windows.Controls.Border; $cell.Padding = '16,11'
        if (-not $first) { $cell.BorderBrush = New-LhvBrush '#D5DDEA'; $cell.BorderThickness = '1,0,0,0' }
        if ($tile.warn) { $cell.Background = New-LhvBrush '#FFEFC9' }
        $stack = New-Object Windows.Controls.StackPanel
        $a = New-Object Windows.Controls.TextBlock; $a.Text = $tile.label; $a.FontSize = 10.5; $a.FontWeight = 'Bold'; $a.Foreground = New-LhvBrush '#5B6B8C'
        $b = New-Object Windows.Controls.TextBlock; $b.Text = "$($tile.value)"; $b.FontSize = 22; $b.FontWeight = 'Bold'; $b.Foreground = New-LhvBrush '#00235F'
        [void]$stack.Children.Add($a); [void]$stack.Children.Add($b); $cell.Child = $stack
        [void]$ui.Tiles.Children.Add($cell)
        $first = $false
    }
}

# -----------------------------------------------------------------------------
#  Show-LhvList
#  Fills the list with the add-ons that match the chosen tab and the search.
#  Unclear add-ons come first, then airports, aircraft and the rest.
# -----------------------------------------------------------------------------
function Show-LhvList {
    $search = "$($ui.SearchBox.Text)".Trim().ToLower()
    $order  = @{ airport = 1; aircraft = 2; livery = 4; mod = 3; library = 5; traffic = 5; navdata = 5; tool = 5; other = 6 }
    $rows   = New-Object System.Collections.Generic.List[object]
    foreach ($e in $script:Entries) {
        $show = $true
        switch ($script:Filter) {
            'airports' { $show = ($e.kind -eq 'airport') }
            'aircraft' { $show = ($e.kind -eq 'aircraft') }
            'mods'     { $show = ($e.kind -notin 'airport','aircraft') }
            'look'     { $show = (-not $e.certain) }
        }
        if (-not $show) { continue }
        $name = $e.folder; if ($e.title -and $e.title -ne $e.folder) { $name = "$($e.title)  ($($e.folder))" }
        $found = Get-LhvFoundText $e
        if ($search -and ("$name $found $($e.sim)".ToLower().IndexOf($search) -lt 0)) { continue }
        $state = 'ok'; $status = 'Recognised'
        if ($e.fixed)            { $state = 'fixed'; $status = 'Fixed by you' }
        elseif (-not $e.certain) { $state = 'look';  $status = 'Needs a look' }
        elseif ($e.kind -notin 'airport','aircraft') { $status = 'Not counted' }
        $sort = 0; if ($e.certain) { $sort = $order[$e.kind] }
        $rows.Add([pscustomobject]@{ State = $state; Status = $status; Kind = $script:KindNames[$e.kind]; Name = $name
                                     Found = $found; Sim = $e.sim; Entry = $e; Sort = $sort })
    }
    $ui.Grid.ItemsSource = @($rows | Sort-Object Sort, Name)
    $has = (@($script:Entries).Count -gt 0)
    $ui.EmptyText.Visibility = 'Collapsed'; if (-not $has) { $ui.EmptyText.Visibility = 'Visible' }
}

# -----------------------------------------------------------------------------
#  Update-LhvResult
#  Redraws everything that depends on the result: numbers, list, steps and
#  the line that says what LH Virtual will use.
# -----------------------------------------------------------------------------
function Update-LhvResult {
    Show-LhvTiles
    Show-LhvList
    $counted = Get-LhvCounted
    $look    = @($script:Entries | Where-Object { -not $_.certain }).Count
    $has     = (@($script:Entries).Count -gt 0)
    foreach ($b in 'SendButton','SaveButton','ShowButton') { $ui[$b].IsEnabled = $has }
    if (-not $has) { return }

    $summary = "$($counted.airports.Count) airports and $($counted.aircraft.Count) aircraft types will be sent."
    if ($look -gt 0) { $summary += " $look add-ons need a look: click one to fix it. Until then they are not counted." }
    if (-not $script:Sent) { $ui.StatusText.Text = $summary; $ui.StatusText.Foreground = New-LhvBrush '#5B6B8C' }

    # One yellow button at a time: "Send" turns yellow once the list is clear.
    $sendStyle = 'BtnPrimary'; if ($look -gt 0 -or $script:Sent) { $sendStyle = 'Btn' }
    $ui.SendButton.Style = $script:Window.FindResource($sendStyle)

    $checkText = 'All clear'; if ($look -gt 0) { $checkText = "$look need a look" }
    if ($script:Sent)      { Show-LhvSteps 5 @('', "$(@($script:Entries).Count) add-ons read", $checkText, 'Done') }
    elseif ($look -gt 0)   { Show-LhvSteps 3 @('', "$(@($script:Entries).Count) add-ons read", $checkText, '') }
    else                   { Show-LhvSteps 4 @('', "$(@($script:Entries).Count) add-ons read", $checkText, '') }
}

# =============================================================================
#  STEP 2: THE SCAN
# =============================================================================

# -----------------------------------------------------------------------------
#  Start-LhvScanFromWindow
#  Runs when you press "Scan now". Reads every add-on folder of the ticked
#  simulators and shows, while it works, which folder is being read.
# -----------------------------------------------------------------------------
function Start-LhvScanFromWindow {
    $sims = @(Get-LhvChosenSimulators)
    if ($sims.Count -eq 0) { $ui.ProgressText.Text = 'Tick at least one simulator.'; return }

    $ui.ScanButton.IsEnabled = $false; $ui.AddFolderButton.IsEnabled = $false
    $ui.Progress.Visibility = 'Visible'; $ui.Progress.Value = 0
    $ui.FixPanel.Visibility = 'Collapsed'
    $script:Sent = $false
    Show-LhvSteps 2 @('', 'Reading ...', '', '')
    Update-LhvWindow

    $script:Entries = @(Invoke-LhvScan -Simulators $sims -OnProgress {
        param($done, $total, $simName, $folderName)
        # Called for every folder: show its name and move the bar.
        $ui.Progress.Value   = [math]::Round(100 * $done / [math]::Max(1, $total))
        $ui.ProgressText.Text = "Reading $done of $total`n$simName  /  $folderName"
        if ($done % 3 -eq 0) { Update-LhvWindow }
    })

    # Apply the corrections you made in an earlier run.
    $script:Entries = @(Use-LhvFixes $script:Entries $script:Fixes)

    $ui.Progress.Visibility = 'Collapsed'
    $ui.ProgressText.Text   = "Done. $(@($script:Entries).Count) add-ons read."
    $ui.ScanButton.Content  = 'Scan again'
    $ui.ScanButton.Style    = $script:Window.FindResource('Btn')       # the yellow button is now "Send"
    $ui.ScanButton.IsEnabled = $true; $ui.AddFolderButton.IsEnabled = $true
    Update-LhvResult
}

# -----------------------------------------------------------------------------
#  Add-LhvFolder
#  "Add another add-on folder": for add-ons kept outside the usual places.
#  You pick the folder; it is read like an MSFS Community folder.
# -----------------------------------------------------------------------------
function Add-LhvFolder {
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Choose a folder that contains add-on folders (for example a second Community folder).'
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    $script:Simulators = @($script:Simulators) + @(@{ id = 'extra'; name = 'Added folder'
        places = @(@{ path = $dialog.SelectedPath; source = 'community'; kind = 'msfs' }) })
    Show-LhvSimulators
}

# =============================================================================
#  STEP 3: QUICK FIX
# =============================================================================

# -----------------------------------------------------------------------------
#  Show-LhvFixPanel
#  Runs when you click an add-on in the list. Shows why it is unclear and
#  lets you say what it is.
# -----------------------------------------------------------------------------
function Show-LhvFixPanel {
    $row = $ui.Grid.SelectedItem
    if (-not $row) { $ui.FixPanel.Visibility = 'Collapsed'; return }
    $e = $row.Entry
    $ui.FixPanel.Visibility = 'Visible'
    $ui.FixError.Visibility = 'Collapsed'
    $ui.FixName.Text = $row.Name
    $note = $e.note
    if (-not $note) {
        if ($e.fixed)                            { $note = 'You set this yourself. "Undo my fix" brings back what the scan found.' }
        elseif ($e.kind -eq 'airport')           { $note = 'The airport code was read from the scenery files. Wrong? Correct it here.' }
        elseif ($e.kind -eq 'aircraft')          { $note = 'The aircraft type was read from the aircraft files. Wrong? Correct it here.' }
        else                                     { $note = 'Not an airport and not an aircraft, so it is not counted. If it is one, say so here.' }
    }
    $ui.FixNote.Text = $note
    $index = 2; if ($e.kind -eq 'airport') { $index = 0 } elseif ($e.kind -eq 'aircraft') { $index = 1 }
    $ui.FixKind.SelectedIndex = $index
    if ($e.kind -eq 'aircraft') { $ui.FixCodes.Text = (@($e.aircraftTypes) -join ', ') } else { $ui.FixCodes.Text = (@($e.icaos | Select-Object -First 12) -join ', ') }
    $ui.FixUndo.IsEnabled = [bool]$e.fixed
    Update-LhvFixFields
}

# -----------------------------------------------------------------------------
#  Update-LhvFixFields
#  The code field changes its label with the kind you choose.
# -----------------------------------------------------------------------------
function Update-LhvFixFields {
    $kind = "$($ui.FixKind.SelectedItem.Tag)"
    $needsCode = ($kind -eq 'airport' -or $kind -eq 'aircraft')
    $ui.FixCodes.IsEnabled = $needsCode
    if     ($kind -eq 'airport')  { $ui.FixCodeLabel.Text = 'ICAO code (e.g. EDDF)' }
    elseif ($kind -eq 'aircraft') { $ui.FixCodeLabel.Text = 'Type code (e.g. A320)' }
    else                          { $ui.FixCodeLabel.Text = 'No code needed' }
}

# -----------------------------------------------------------------------------
#  Set-LhvFixFromWindow
#  Runs when you press "Apply". Checks what you typed, changes the add-on in
#  the list and remembers the correction for the next scan.
# -----------------------------------------------------------------------------
function Set-LhvFixFromWindow {
    $row = $ui.Grid.SelectedItem
    if (-not $row) { return }
    $e     = $row.Entry
    $kind  = "$($ui.FixKind.SelectedItem.Tag)"
    $codes = @("$($ui.FixCodes.Text)".ToUpper() -split '[\s,;]+' | Where-Object { $_ })

    # Check the codes before anything is changed.
    $problem = ''
    if ($kind -eq 'airport') {
        if ($codes.Count -eq 0) { $problem = 'Enter the ICAO code of the airport, for example EDDF.' }
        elseif (@($codes | Where-Object { $_ -notmatch '^[A-Z0-9]{3,8}$' }).Count -gt 0) { $problem = 'An airport code has 3 to 8 letters or digits, for example EDDF.' }
    } elseif ($kind -eq 'aircraft') {
        if ($codes.Count -eq 0) { $problem = 'Enter the type code of the aircraft, for example A320.' }
        elseif (@($codes | Where-Object { $_ -notmatch '^[A-Z0-9]{2,4}$' }).Count -gt 0) { $problem = 'A type code has 2 to 4 letters or digits, for example A320 or B77W.' }
    }
    if ($problem) { $ui.FixError.Text = $problem; $ui.FixError.Visibility = 'Visible'; return }

    $icaos = @(); $types = @()
    if ($kind -eq 'airport')  { $icaos = $codes }
    if ($kind -eq 'aircraft') { $types = $codes }
    if (-not $e.Contains('scanned')) {
        # Keep what the scan found, so "Undo my fix" can bring it back.
        $e.scanned = @{ kind = $e.kind; detail = $e.detail; icaos = @($e.icaos); aircraftTypes = @($e.aircraftTypes); certain = $e.certain; note = $e.note }
    }
    [void](Set-LhvFix $e $kind $icaos $types)
    $script:Fixes["$($e.sim)|$($e.folder)"] = @{ kind = $kind; icaos = $icaos; aircraftTypes = $types }
    Save-LhvFixes $script:Fixes
    $script:Sent = $false
    Update-LhvResult
    $ui.FixPanel.Visibility = 'Collapsed'
}

# -----------------------------------------------------------------------------
#  Undo-LhvFixFromWindow
#  "Undo my fix": forgets your correction for the selected add-on.
# -----------------------------------------------------------------------------
function Undo-LhvFixFromWindow {
    $row = $ui.Grid.SelectedItem
    if (-not $row) { return }
    $e = $row.Entry
    $script:Fixes.Remove("$($e.sim)|$($e.folder)")
    Save-LhvFixes $script:Fixes
    if ($e.Contains('scanned')) {
        foreach ($key in 'kind','detail','icaos','aircraftTypes','certain','note') { $e[$key] = $e.scanned[$key] }
        $e.fixed = $false
        $e.Remove('scanned')
    } else {
        # The fix came from an earlier run: only a new scan knows the original.
        $e.fixed = $false; $e.certain = $false; $e.note = 'Your fix was removed. Press "Scan again" to read this add-on anew.'
    }
    $script:Sent = $false
    Update-LhvResult
    $ui.FixPanel.Visibility = 'Collapsed'
}

# =============================================================================
#  STEP 4: SEND OR SAVE
# =============================================================================

# -----------------------------------------------------------------------------
#  Show-LhvFileText
#  "Show what is sent": opens a small window with the exact text of the list.
#  This is the same text that "Send to My sim" sends and "Save as file" saves.
# -----------------------------------------------------------------------------
function Show-LhvFileText {
    $view = New-Object Windows.Window
    $view.Title = 'LHV Scan - this is what is sent'; $view.Width = 720; $view.Height = 620
    $view.Owner = $script:Window; $view.WindowStartupLocation = 'CenterOwner'
    $box = New-Object Windows.Controls.TextBox
    $box.Text = ConvertTo-LhvAddonFile $script:Entries
    $box.IsReadOnly = $true; $box.FontFamily = 'Consolas'; $box.FontSize = 12.5
    $box.VerticalScrollBarVisibility = 'Auto'; $box.HorizontalScrollBarVisibility = 'Auto'
    $box.BorderThickness = 0; $box.Padding = 14
    $view.Content = $box
    [void]$view.ShowDialog()
}

# -----------------------------------------------------------------------------
#  Save-LhvFileFromWindow
#  "Save as file": you choose where; the list is written there. You can then
#  upload that file yourself on the My sim page.
# -----------------------------------------------------------------------------
function Save-LhvFileFromWindow {
    $dialog = New-Object Microsoft.Win32.SaveFileDialog
    $dialog.FileName = 'lhv-addons.json'; $dialog.Filter = 'LHV add-on list (*.json)|*.json'
    $dialog.InitialDirectory = [Environment]::GetFolderPath('Desktop')
    if (-not $dialog.ShowDialog($script:Window)) { return }
    Save-LhvAddonFile $script:Entries $dialog.FileName
    $script:Sent = $true
    $ui.StatusText.Text = "Saved. Now open My sim at LH Virtual and press `"Upload file`"."
    $ui.StatusText.Foreground = New-LhvBrush '#0A7D3C'
    Update-LhvResult
}

# -----------------------------------------------------------------------------
#  Send-LhvFromWindow
#  Runs when you press "Send to My sim". The sending itself is done by
#  Send-LhvList in scan-send.ps1 - the only place that uses the internet.
# -----------------------------------------------------------------------------
function Send-LhvFromWindow {
    $code = ("$($ui.CodeBox.Text)" -replace '[^A-Za-z0-9]', '').ToUpper()
    if ($code.Length -lt 6) {
        $ui.StatusText.Text = 'Type the code from your My sim page first: open My sim at LH Virtual and press "Connect the scan tool".'
        $ui.StatusText.Foreground = New-LhvBrush '#B3261E'
        $ui.CodeBox.Focus() | Out-Null
        return
    }
    $ui.SendButton.IsEnabled = $false
    $ui.StatusText.Text = 'Sending ...'; $ui.StatusText.Foreground = New-LhvBrush '#5B6B8C'
    Update-LhvWindow
    $result = Send-LhvList -Code $code -FileText (ConvertTo-LhvAddonFile $script:Entries)
    $ui.SendButton.IsEnabled = $true
    $ui.StatusText.Text = $result.message
    if ($result.ok) {
        $ui.StatusText.Foreground = New-LhvBrush '#0A7D3C'
        $script:Sent = $true
        Update-LhvResult
        $ui.StatusText.Text = $result.message
    } else {
        $ui.StatusText.Foreground = New-LhvBrush '#B3261E'
    }
}

# =============================================================================
#  A MADE-UP LIST FOR A FIRST LOOK  (LHV-Scan.ps1 -Demo)
# =============================================================================
function Get-LhvDemoEntries {
    $list = @()
    $add = {
        param($folder, $title, $kind, $detail, $icaos, $types, $certain, $note)
        $e = New-LhvEntry 'MSFS 2024' 'community' $folder
        $e.title = $title; $e.kind = $kind; $e.detail = $detail; $e.icaos = @($icaos); $e.aircraftTypes = @($types)
        $e.certain = $certain; $e.note = $note
        return $e
    }
    $list += & $add 'aerosoft-airport-eddf-frankfurt' 'Frankfurt Airport' 'airport' '' @('EDDF') @() $true ''
    $list += & $add 'simwings-airport-eddm-munich' 'Munich Airport' 'airport' '' @('EDDM') @() $true ''
    $list += & $add 'flytampa-airport-eham-amsterdam' 'Amsterdam Schiphol' 'airport' '' @('EHAM') @() $true ''
    $list += & $add 'mkstudios-airport-lppt-lisbon' 'Lisbon' 'airport' '' @('LPPT') @() $true ''
    $list += & $add 'fnx-aircraft-320' 'Fenix A320' 'aircraft' '' @() @('A320') $true ''
    $list += & $add 'pmdg-aircraft-77w' 'PMDG 777-300ER' 'aircraft' '' @() @('B77W') $true ''
    $list += & $add 'inibuilds-aircraft-a350' 'iniBuilds A350' 'aircraft' '' @() @('A359', 'A35K') $true ''
    $list += & $add 'fnx-aircraft-320-liveries' 'Fenix A320 liveries' 'livery' 'Livery' @() @() $true ''
    $list += & $add 'bijan-seasons-trees' 'Seasons and tree fix' 'mod' 'Tree fix' @() @() $true ''
    $list += & $add 'fsltl-traffic-base' 'FSLTL traffic' 'traffic' 'AI traffic' @() @() $true ''
    $list += & $add 'navigraph-navdata' 'Navigraph navdata' 'navdata' 'Navigation data' @() @() $true ''
    $list += & $add 'eddf-jetway-fix' 'Frankfurt jetway fix' 'airport' 'Jetways or ground' @('EDDF') @() $false 'Looks like a mod for EDDF, not the airport itself.'
    $list += & $add 'my-home-airfield' 'My home airfield' 'other' 'Scenery without an airport inside' @() @() $false 'Named like an airport, but no airport was found inside. Which airport is it?'
    $list += & $add 'some-airliner-v2' 'Some Airliner' 'aircraft' '' @() @() $false 'The aircraft files do not name a type. Which type is it?'
    return $list
}

# =============================================================================
#  CONNECT THE BUTTONS AND START
# =============================================================================
$ui.ScanButton.Add_Click({ Start-LhvScanFromWindow })
$ui.AddFolderButton.Add_Click({ Add-LhvFolder })
$ui.Grid.Add_SelectionChanged({ Show-LhvFixPanel })
$ui.FixKind.Add_SelectionChanged({ Update-LhvFixFields })
$ui.FixApply.Add_Click({ Set-LhvFixFromWindow })
$ui.FixUndo.Add_Click({ Undo-LhvFixFromWindow })
$ui.SearchBox.Add_TextChanged({ Show-LhvList })
$ui.ShowButton.Add_Click({ Show-LhvFileText })
$ui.SaveButton.Add_Click({ Save-LhvFileFromWindow })
$ui.SendButton.Add_Click({ Send-LhvFromWindow })
foreach ($pair in @(@('TabAll','all'), @('TabAirports','airports'), @('TabAircraft','aircraft'), @('TabMods','mods'), @('TabLook','look'))) {
    $name = $pair[0]; $value = $pair[1]
    $ui[$name].Tag = $value
    $ui[$name].Add_Checked({ param($sender) $script:Filter = "$($sender.Tag)"; Show-LhvList })
}

# Step 1 happens right away: which simulators are on this PC?
$script:Fixes = Read-LhvFixes
if ($Demo) {
    $script:Simulators = @(@{ id = 'msfs2024'; name = 'MSFS 2024 (demo)'; places = @(@{ path = 'D:\MSFS 2024\Community'; source = 'community'; kind = 'msfs' }) })
} else {
    $script:Simulators = @(Get-LhvSimulators)
}
Show-LhvSimulators
Show-LhvSteps 2 @("$(@($script:Simulators).Count) found", '', '', '')
Update-LhvResult
if ($Demo) {
    $script:Entries = @(Get-LhvDemoEntries)
    $ui.ProgressText.Text = 'Demo: a made-up list. Nothing was read.'
    $ui.ScanButton.IsEnabled = $false
    $ui.ScanButton.Style = $script:Window.FindResource('Btn')
    Update-LhvResult
}

if ($Screenshot) {
    # Documentation only: draw the window, save a picture of it, close.
    $script:Window.Add_ContentRendered({
        if ($Demo) { $ui.Grid.SelectedIndex = 0; Show-LhvFixPanel }
        else       { Start-LhvScanFromWindow }                 # a real scan, then the picture
        Update-LhvWindow
        $root   = $script:Window.Content
        $bitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap([int]($root.ActualWidth * 1.5), [int]($root.ActualHeight * 1.5), 144, 144, [Windows.Media.PixelFormats]::Pbgra32)
        $bitmap.Render($root)
        $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
        $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $file = [IO.File]::Create($Screenshot); $encoder.Save($file); $file.Dispose()
        $script:Window.Close()
    })
}

[void]$script:Window.ShowDialog()
