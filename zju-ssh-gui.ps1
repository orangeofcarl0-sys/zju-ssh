# zju-ssh-gui.ps1 — ZJU SSH 助手 v3（WPF 深色界面，设计语言参考 Clash Verge / WireGuard / ZJU-Connect）
# 系统自带 WPF（PresentationFramework），零外部依赖。双击"启动设置界面.bat"打开。
# 日常连接不需要本窗口：任何网络下 ssh zju 即可。
# 所有操作调用同目录 zju-ssh.ps1（重逻辑已测试）；子进程输出落文件 + DispatcherTimer 轮询回显，UI 不冻结。

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $toolDir 'zju-common.psm1') -Force -DisableNameChecking
$mainPs1 = Join-Path $toolDir 'zju-ssh.ps1'
$cfgLocal = Join-Path $env:LOCALAPPDATA 'zju-ssh\config.json'
$cfgTool = Join-Path $toolDir 'config.json'
$taskTun = 'ZJUSSH-Tunnel'

$cfg0 = Get-ToolConfig -LocalPath $cfgLocal -ToolPath $cfgTool
$script:theme = Get-CfgValue -Cfg $cfg0 -Key 'theme'
if ($script:theme -ne 'light' -and $script:theme -ne 'dark') { $script:theme = 'dark' }

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ZJU SSH 助手" Height="680" Width="920"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize"
        Background="#14141C">
  <Window.Resources>
    <SolidColorBrush x:Key="CardBrush" Color="#1E1E2A"/>
    <SolidColorBrush x:Key="CardBorder" Color="#2C2C3E"/>
    <SolidColorBrush x:Key="Accent" Color="#4F8CFF"/>
    <SolidColorBrush x:Key="TextMain" Color="#EAEAF2"/>
    <SolidColorBrush x:Key="TextDim" Color="#8A8AA0"/>
    <SolidColorBrush x:Key="InputBg" Color="#232333"/>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource CardBrush}"/>
      <Setter Property="BorderBrush" Value="{StaticResource CardBorder}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="18"/>
    </Style>
    <Style x:Key="CardTitle" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource TextDim}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Margin" Value="0,0,0,10"/>
    </Style>
    <Style x:Key="Lbl" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource TextDim}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Margin" Value="0,0,10,0"/>
    </Style>
    <Style x:Key="Inp" TargetType="TextBox">
      <Setter Property="Background" Value="{StaticResource InputBg}"/>
      <Setter Property="Foreground" Value="{StaticResource TextMain}"/>
      <Setter Property="BorderBrush" Value="#3A3A50"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="Padding" Value="8,5"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="CaretBrush" Value="{StaticResource TextMain}"/>
    </Style>
    <Style x:Key="AccBtn" TargetType="Button">
      <Setter Property="Background" Value="{StaticResource Accent}"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Height" Value="46"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="{TemplateBinding Background}" CornerRadius="10">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Background" Value="#6BA0FF"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Background" Value="#2E2E40"/>
                <Setter Property="Foreground" Value="#77778E"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="GhostBtn" TargetType="Button">
      <Setter Property="Background" Value="#26263A"/>
      <Setter Property="Foreground" Value="{StaticResource TextMain}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="{TemplateBinding Background}" BorderBrush="#3A3A50" BorderThickness="1" CornerRadius="8">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Background" Value="#32324A"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Foreground" Value="#66667E"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal">
              <Grid Width="44" Height="22" VerticalAlignment="Center">
                <Border x:Name="track" CornerRadius="11" Background="#3A3A50"/>
                <Ellipse x:Name="thumb" Width="16" Height="16" Fill="#8888A0"
                         HorizontalAlignment="Left" Margin="4,0,0,0"/>
              </Grid>
              <ContentPresenter Margin="10,0,0,0" VerticalAlignment="Center"
                                TextBlock.Foreground="{StaticResource TextMain}" TextBlock.FontSize="12"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="track" Property="Background" Value="{StaticResource Accent}"/>
                <Setter TargetName="thumb" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="thumb" Property="Fill" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="DarkCombo" TargetType="ComboBox">
      <Setter Property="Foreground" Value="{StaticResource TextMain}"/>
      <Setter Property="Background" Value="{StaticResource InputBg}"/>
      <Setter Property="BorderBrush" Value="#3A3A50"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="ItemContainerStyle">
        <Setter.Value>
          <Style TargetType="ComboBoxItem">
            <Setter Property="Foreground" Value="{StaticResource TextMain}"/>
            <Setter Property="Padding" Value="10,7"/>
            <Setter Property="Template">
              <Setter.Value>
                <ControlTemplate TargetType="ComboBoxItem">
                  <Border Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
                    <ContentPresenter/>
                  </Border>
                  <ControlTemplate.Triggers>
                    <Trigger Property="IsHighlighted" Value="True">
                      <Setter Property="Background" Value="#32324A"/>
                    </Trigger>
                    <Trigger Property="IsSelected" Value="True">
                      <Setter Property="Foreground" Value="#4F8CFF"/>
                    </Trigger>
                  </ControlTemplate.Triggers>
                </ControlTemplate>
              </Setter.Value>
            </Setter>
          </Style>
        </Setter.Value>
      </Setter>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton x:Name="toggle" Focusable="False" ClickMode="Press"
                            Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                            BorderThickness="1" CornerRadius="6">
                      <Path HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,10,0"
                            Data="M 0 0 L 4.5 4.5 L 9 0 Z" Fill="#8A8AA0"/>
                    </Border>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter Content="{TemplateBinding SelectionBoxItem}"
                                ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                Margin="10,0,26,0" VerticalAlignment="Center" IsHitTestVisible="False"
                                TextBlock.Foreground="{StaticResource TextMain}" TextBlock.FontSize="12"/>
              <Popup x:Name="PART_Popup" IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom"
                     AllowsTransparency="True" PopupAnimation="Slide" Focusable="False">
                <Border Background="#232333" BorderBrush="#3A3A50" BorderThickness="1" CornerRadius="6"
                        MinWidth="{TemplateBinding ActualWidth}" Margin="0,4,0,0">
                  <ScrollViewer MaxHeight="180">
                    <ItemsPresenter/>
                  </ScrollViewer>
                </Border>
              </Popup>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="NavBtn" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{StaticResource TextDim}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="8,4"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="bd" Background="Transparent" CornerRadius="8" Padding="12,10">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#2A2A44"/>
                <Setter Property="Foreground" Value="{StaticResource TextMain}"/>
              </Trigger>
              <MultiTrigger>
                <MultiTrigger.Conditions>
                  <Condition Property="IsMouseOver" Value="True"/>
                  <Condition Property="IsChecked" Value="False"/>
                </MultiTrigger.Conditions>
                <Setter TargetName="bd" Property="Background" Value="#20202F"/>
              </MultiTrigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="138"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <Border Grid.ColumnSpan="2" Background="#181820" BorderBrush="#2C2C3E" BorderThickness="0,0,0,1" Padding="18,12">
      <DockPanel LastChildFill="False">
        <StackPanel Orientation="Vertical">
          <TextBlock Text="ZJU SSH 助手" Foreground="{StaticResource TextMain}" FontSize="16" FontWeight="Bold"/>
          <TextBlock Text="校内直连 · 校外经 RVPN 隧道 · 配置一次，ssh zju 走天下" Foreground="{StaticResource TextDim}" FontSize="11"/>
        </StackPanel>
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,6,0">
          <Button x:Name="btnTheme" Content="🌙" Width="34" Height="28" Style="{StaticResource GhostBtn}" FontSize="13"/>
          <Border CornerRadius="13" Background="#23233A" Padding="12,6" VerticalAlignment="Center">
          <StackPanel Orientation="Horizontal">
            <Ellipse x:Name="dot" Width="10" Height="10" Fill="#77778E" Margin="0,0,8,0" VerticalAlignment="Center"/>
            <TextBlock x:Name="pillText" Text="检测中…" Foreground="{StaticResource TextMain}" FontSize="12" VerticalAlignment="Center"/>
          </StackPanel>
        </Border>
        </StackPanel>
      </DockPanel>
    </Border>

    <Border Grid.Row="1" Grid.Column="0" Background="#181820" BorderBrush="#2C2C3E" BorderThickness="0,0,1,0">
      <StackPanel Margin="10,16,10,10">
        <RadioButton x:Name="navHome" Style="{StaticResource NavBtn}" GroupName="nav" IsChecked="True" Content="⌂  主页"/>
        <RadioButton x:Name="navSettings" Style="{StaticResource NavBtn}" GroupName="nav" Margin="0,6,0,0" Content="⚙  设置"/>
        <TextBlock Margin="14,26,0,0" Text="ZJU SSH" Foreground="#4A4A60" FontSize="10"/>
        <TextBlock x:Name="verText" Margin="14,2,0,0" Text="v1.4.6" Foreground="#4A4A60" FontSize="10"/>
      </StackPanel>
    </Border>

    <Grid Grid.Row="1" Grid.Column="1" Margin="18,14,18,14">
      <Border x:Name="pageHome" Style="{StaticResource Card}">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <Grid Grid.Row="0" Margin="0,0,0,4">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0">
              <TextBlock Style="{StaticResource Lbl}" Text="工作站"/>
              <TextBlock x:Name="homeTarget" Text="—" Foreground="{StaticResource TextMain}" FontSize="14" FontWeight="Bold"/>
            </StackPanel>
            <StackPanel Grid.Column="1">
              <TextBlock Style="{StaticResource Lbl}" Text="ssh 别名"/>
              <TextBlock x:Name="homeAlias" Text="—" Foreground="{StaticResource TextMain}" FontSize="14" FontWeight="Bold"/>
            </StackPanel>
          </Grid>
          <StackPanel Grid.Row="1">
            <TextBlock x:Name="heroStatus" Text="检测中…" Foreground="{StaticResource TextMain}" FontSize="20" FontWeight="Bold"
                       HorizontalAlignment="Center"/>
            <TextBlock x:Name="heroSub" Text="未连接。校外环境点下方按钮自动建立隧道；校内直接 ssh zju。"
                       Foreground="{StaticResource TextDim}" FontSize="11" HorizontalAlignment="Center" Margin="0,6,0,10"/>
            <ProgressBar x:Name="prog" Height="4" IsIndeterminate="True" Visibility="Collapsed" Margin="0,0,0,10"/>
            <Button x:Name="btnConnect" Style="{StaticResource AccBtn}" Content="一键连接 ZJU"/>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,12,0,0">
              <Button x:Name="btnDoctor" Style="{StaticResource GhostBtn}" Content="自检并复制诊断信息" Width="180" Margin="0,0,12,0"/>
              <Button x:Name="btnDown" Style="{StaticResource GhostBtn}" Content="停止校外隧道" Width="150"/>
            </StackPanel>
            <TextBlock Text="日常连接不需要打开本窗口：任何终端 ssh zju 即可。"
                       Foreground="#66667E" FontSize="11" HorizontalAlignment="Center" Margin="0,10,0,0"/>
          </StackPanel>
          <Border Grid.Row="2" Height="1" Background="{StaticResource CardBorder}" Margin="0,12,0,8"/>
          <TextBlock Grid.Row="3" Style="{StaticResource CardTitle}" Text="实时日志（隧道建立过程与 zju-connect 活动，排障依据）" Margin="0,0,0,6"/>
          <TextBox Grid.Row="4" x:Name="txtLog" Background="#101018" Foreground="#9FE0B0"
                   BorderBrush="#2C2C3E" BorderThickness="1" IsReadOnly="True"
                   FontFamily="Consolas" FontSize="11" VerticalScrollBarVisibility="Auto"
                   TextWrapping="NoWrap"/>
        </Grid>
      </Border>

      <Border x:Name="pageSettings" Style="{StaticResource Card}" Visibility="Collapsed">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel>
            <TextBlock Style="{StaticResource CardTitle}" Text="连接配置（改动后点“保存配置”，日常无需再动）"/>
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="24"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="12"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="12"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="12"/>
                <RowDefinition Height="Auto"/>
              </Grid.RowDefinitions>
              <StackPanel Grid.Row="0" Grid.Column="0">
                <TextBlock Style="{StaticResource Lbl}" Text="工作站地址（必填，管理员告知）"/>
                <TextBox x:Name="tSshHost" Style="{StaticResource Inp}"/>
              </StackPanel>
              <StackPanel Grid.Row="0" Grid.Column="2">
                <TextBlock Style="{StaticResource Lbl}" Text="SSH 端口"/>
                <TextBox x:Name="tSshPort" Style="{StaticResource Inp}"/>
              </StackPanel>
              <StackPanel Grid.Row="2" Grid.Column="0">
                <TextBlock Style="{StaticResource Lbl}" Text="ZJU SSH 账户"/>
                <TextBox x:Name="tSshUser" Style="{StaticResource Inp}"/>
              </StackPanel>
              <StackPanel Grid.Row="2" Grid.Column="2">
                <TextBlock Style="{StaticResource Lbl}" Text="校园网/VPN 上网账号（学号或工号）"/>
                <TextBox x:Name="tVpnUser" Style="{StaticResource Inp}"/>
              </StackPanel>
              <StackPanel Grid.Row="4" Grid.Column="0">
                <TextBlock Style="{StaticResource Lbl}" Text="通道模式"/>
                <ComboBox x:Name="cmoMode" Style="{StaticResource DarkCombo}">
                    <ComboBoxItem Content="TUN（推荐，需一次管理员授权）" IsSelected="True"/>
                  <ComboBoxItem Content="SOCKS（免管理员，用 Git Bash ssh）"/>
                </ComboBox>
              </StackPanel>
              <StackPanel Grid.Row="4" Grid.Column="2">
                <TextBlock Style="{StaticResource Lbl}" Text="上网密码"/>
                <TextBox x:Name="tVpnPass" Style="{StaticResource Inp}"/>
              </StackPanel>
              <StackPanel Grid.Row="6" Grid.Column="0" Orientation="Horizontal">
                <CheckBox x:Name="tglAuto" Style="{StaticResource Switch}" Content="开机自动启动校外隧道（TUN）"/>
              </StackPanel>
              <StackPanel Grid.Row="6" Grid.Column="2" Orientation="Horizontal" HorizontalAlignment="Right">
                <Button x:Name="btnApply" Style="{StaticResource GhostBtn}" Content="保存配置" Width="110" Margin="0,0,10,0"/>
                <Button x:Name="btnKey" Style="{StaticResource GhostBtn}" Content="生成/复制公钥" Width="130"/>
              </StackPanel>
            </Grid>
            <Expander Header="高级：ssh 别名 / RVPN 服务器（一般无需改动）" Foreground="#8A8AA0" FontSize="12" Margin="0,16,0,0">
              <Grid Margin="0,10,0,0">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="20"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0">
                  <TextBlock Style="{StaticResource Lbl}" Text="ssh 别名（config 里的 Host 名）"/>
                  <TextBox x:Name="tAlias" Style="{StaticResource Inp}"/>
                </StackPanel>
                <StackPanel Grid.Column="2">
                  <TextBlock Style="{StaticResource Lbl}" Text="RVPN 服务器:端口（冒号分隔）"/>
                  <TextBox x:Name="tZjuServer" Style="{StaticResource Inp}"/>
                </StackPanel>
              </Grid>
            </Expander>
          </StackPanel>
        </ScrollViewer>
      </Border>
    </Grid>
  </Grid>
</Window>
'@

# 主题调色板：明暗切换通过在 XAML 文本注入前替换色值实现
if ($script:theme -eq 'light') {
    $pal = [ordered]@{
        '#14141C' = '#F3F4F8'; '#181820' = '#FFFFFF'; '#1E1E2A' = '#FFFFFF'
        '#2C2C3E' = '#E2E5EF'; '#23233A' = '#EDF0F7'; '#232333' = '#FFFFFF'
        '#3A3A50' = '#D4D8E4'; '#EAEAF2' = '#1B1F2A'; '#8A8AA0' = '#6C7284'
        '#66667E' = '#9AA0AE'; '#4A4A60' = '#B4B8C4'; '#26263A' = '#EEF1F7'
        '#32324A' = '#E7EBF5'; '#2A2A44' = '#E3EBFF'; '#20202F' = '#F0F2F8'
        '#101018' = '#F7F8FB'; '#9FE0B0' = '#1A7F37'; '#2E2E40' = '#E3E6EF'
        '#77778E' = '#9AA0AE'; '#8888A0' = '#FFFFFF'
    }
    foreach ($k in $pal.Keys) { $xaml = $xaml.Replace($k, $pal[$k]) }
}

[xml]$xamlDoc = $xaml
$reader = New-Object System.Xml.XmlNodeReader $xamlDoc
$window = [Windows.Markup.XamlReader]::Load($reader)
$ui = @{}
foreach ($n in @('dot','pillText','heroStatus','heroSub','prog','btnConnect','tSshUser','tVpnUser','tVpnPass','cmoMode','tglAuto','btnApply','btnKey','btnDoctor','btnDown','txtLog','tSshHost','tSshPort','tAlias','tZjuServer','pageHome','pageSettings','navHome','navSettings','verText','btnTheme','homeTarget','homeAlias')) {
    $ui[$n] = $window.FindName($n)
}
$ui.btnTheme.Content = if ($script:theme -eq 'dark') { '☀' } else { '🌙' }
$ui.verText.Text = 'v' + (Get-ToolVersion)

$cfg = Get-ToolConfig -LocalPath $cfgLocal -ToolPath $cfgTool
if ($cfg) {
    $ui.tSshUser.Text = [string]$cfg.sshUser
    $ui.tVpnUser.Text = [string]$cfg.vpnUser
    $ui.tVpnPass.Text = [string]$cfg.vpnPassword
    $ui.tSshHost.Text = [string]$cfg.sshHost
    $ui.tSshPort.Text = [string]$cfg.sshPort
    $ui.tAlias.Text = [string]$cfg.hostAlias
    $ui.tZjuServer.Text = ([string]$cfg.server + ':' + [string]$cfg.zjuPort)
    if ($cfg.mode -eq 'socks') { $ui.cmoMode.SelectedIndex = 1 } else { $ui.cmoMode.SelectedIndex = 0 }
}
$ui.verText.Text = 'v' + (Get-ToolVersion)

$script:runLog = New-Object System.Collections.Generic.List[string]
function Append-Log([string]$text) {
    $ui.txtLog.AppendText($text + "`r`n")
    $ui.txtLog.ScrollToEnd()
    $script:runLog.Add($text)
}

function Show-Page([string]$p) {
    $ui.pageHome.Visibility = if ($p -eq 'home') { 'Visible' } else { 'Collapsed' }
    $ui.pageSettings.Visibility = if ($p -eq 'settings') { 'Visible' } else { 'Collapsed' }
}

$script:proc = $null
$script:outF = $null
$script:errF = $null
$script:posO = 0
$script:posE = 0
$script:copyOnDone = $false
$script:tick = 0
$script:zjuWasRun = $false
$script:zjuTailPos = 0
$script:zjuTailF = ''
$script:guiMode = ''
$script:reallyExit = $false

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(400)

function Set-Status([string]$color, [string]$pill, [string]$hero, [string]$sub) {
    $conv = [System.Windows.Media.ColorConverter]::ConvertFromString($color)
    $ui.dot.Fill = New-Object System.Windows.Media.SolidColorBrush $conv
    $ui.pillText.Text = $pill
    $ui.heroStatus.Text = $hero
    $ui.heroStatus.Foreground = New-Object System.Windows.Media.SolidColorBrush $conv
    if ($sub) { $ui.heroSub.Text = $sub }
}

function Set-Busy([bool]$b, [string]$why) {
    foreach ($c in @($ui.btnApply, $ui.btnKey, $ui.btnDoctor, $ui.btnConnect, $ui.btnDown, $ui.tglAuto)) { $c.IsEnabled = -not $b }
    if ($b) { $ui.prog.Visibility = 'Visible'; Set-Status 'Goldenrod' "正在$why…" "正在$why…" $null }
    else { $ui.prog.Visibility = 'Collapsed'; Update-StatusQuiet }
}

function Probe-Direct {
    # 校内直连探测（“一键连接”先走这里）：工作站端口可达 = 校内网络，无需建隧道
    $c = Get-ToolConfig -LocalPath $cfgLocal -ToolPath $cfgTool
    if (-not $c) { return $false }
    $h = Get-CfgValue -Cfg $c -Key 'sshHost'
    if (-not $h) { return $false }
    return (Test-TcpPort -h $h -p ([int](Get-CfgValue -Cfg $c -Key 'sshPort')) -ms 600)
}

function Update-StatusQuiet {
    $cfg = Get-ToolConfig -LocalPath $cfgLocal -ToolPath $cfgTool
    $script:guiMode = Get-CfgValue -Cfg $cfg -Key 'mode'
    $al = Get-CfgValue -Cfg $cfg -Key 'hostAlias'
    $h = Get-CfgValue -Cfg $cfg -Key 'sshHost'
    $p = [int](Get-CfgValue -Cfg $cfg -Key 'sshPort')
    $ui.homeTarget.Text = if ($h) { ("{0}:{1}" -f $h, $p) } else { '—' }
    $ui.homeAlias.Text = if ($al) { $al } else { '—' }
    if (-not $h) { Set-Status '#77778E' '未配置工作站地址' '未配置工作站地址' '在“设置”页第一行填写工作站地址并保存配置。'; return }
    if (Test-TcpPort -h $h -p $p -ms 500) { Set-Status '#2ECC71' '已连接 · 校内直连' '已连接' ('当前为校内网络，任何终端执行 ssh ' + $al + ' 即可。') }
    elseif (Test-SocksReady) { Set-Status '#F39C12' '校外隧道运行中' '校外隧道运行中' ('流量已可经 RVPN 隧道直达校园网，直接 ssh ' + $al + '。') }
    elseif (Get-ZjuProc) { Set-Status '#F39C12' '隧道启动中…' '隧道启动中…' 'zju-connect 进程存在，等待隧道就绪（10-30 秒）。' }
    else { Set-Status '#77778E' '未连接' '未连接' ('校外环境请点“一键连接 ZJU”自动建立隧道，然后 ssh ' + $al + '。') }
}

function Read-Grow([string]$path, [ref]$pos) {
    if (-not (Test-Path $path)) { return }
    $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
    try {
        $fs.Position = $pos.Value
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
        $chunk = $sr.ReadToEnd()
        $pos.Value = [int]$fs.Position
        if ($chunk) { Append-Log $chunk.TrimEnd() }
    } finally { $fs.Close() }
}

$timer.Add_Tick({
    if (-not $script:proc) {
        $script:tick++
        if ($script:tick -ge 40) { $script:tick = 0; Update-StatusQuiet }
        # zju-connect 运行日志实时跟踪（隧道长驻，生命周期独立于 CLI 子任务；TUN/SOCKS 均有落盘日志）
        $zj = Get-ZjuProc
        if ($zj) {
            if (-not $script:zjuWasRun) {
                $script:zjuWasRun = $true
                $script:zjuTailPos = 0
                $script:zjuNoLogHinted = $false
                $script:zjuTailF = if ($script:guiMode -eq 'tun') { Join-Path $toolDir 'logs\zju-tun.log' } else { Join-Path $toolDir 'logs\zju-out.log' }
                Append-Log '── zju-connect 运行日志（实时跟踪） ──'
            }
            if ((Test-Path $script:zjuTailF) -or $script:zjuNoLogHinted) {
                Read-Grow $script:zjuTailF ([ref]$script:zjuTailPos)
            } elseif ($script:tick -ge 8) {
                # 进程在跑但没有它的运行日志：多半是旧计划任务/旧内核启动的残留，给一条自救指引
                $script:zjuNoLogHinted = $true
                Append-Log '（尚未发现该进程的运行日志——建议点「停止校外隧道」结束后重新一键连接，以启用当前版本的内核与日志）'
            }
        } elseif ($script:zjuWasRun) {
            $script:zjuWasRun = $false
            Append-Log '■ 隧道进程已退出'
        }
        return
    }
    Read-Grow $script:outF ([ref]$script:posO)
    Read-Grow $script:errF ([ref]$script:posE)
    if ($script:proc.HasExited) {
        Read-Grow $script:outF ([ref]$script:posO)
        Read-Grow $script:errF ([ref]$script:posE)
        # 先取一次 Handle：进程退出后 ExitCode 只有在句柄已打开时才可读，否则恒为空
        $code = $script:proc.ExitCode
        $timer.Stop()
        $script:proc = $null
        Remove-Item Env:\ZJU_SSH_VPNPASS -ErrorAction SilentlyContinue   # 用后即清
        Remove-Item Env:\ZJU_SSH_NONINTERACTIVE -ErrorAction SilentlyContinue   # 用后即清
        Set-Busy $false ''
        Append-Log "■ 完成（退出码 $code）"
        if ($script:copyOnDone) {
            try {
                [System.Windows.Clipboard]::SetText(($script:runLog -join "`r`n"))
                Append-Log '★ 诊断信息已复制到剪贴板，直接粘贴发给管理员即可。'
            } catch { Append-Log '（复制到剪贴板失败，请手动从上方日志框全选复制）' }
        }
        Update-StatusQuiet
    }
})

function Start-Tool([string]$argline, [string]$title, [bool]$copyOnDone) {
    if ($script:proc) { Append-Log '已有任务在运行，请稍候…'; return }
    $script:runLog.Clear()
    $script:copyOnDone = $copyOnDone
    $script:outF = [System.IO.Path]::GetTempFileName()
    $script:errF = [System.IO.Path]::GetTempFileName()
    Append-Log "▶ $title"
    $script:posO = 0; $script:posE = 0
    $script:proc = Start-Process powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $mainPs1 + '"'),$argline) `
        -RedirectStandardOutput $script:outF -RedirectStandardError $script:errF -PassThru -WindowStyle Hidden
    # 立即开句柄：若子进程在首个 tick 前就退出，未开过句柄的 ExitCode 读取会失败（此前"退出码 "为空的根因）
    $null = $script:proc.Handle
    Set-Busy $true $title
    $timer.Start()
}

$ui.btnConnect.Add_Click({
    if (Probe-Direct) { Update-StatusQuiet; Append-Log '✓ 当前为校内网络，可直连，无需隧道（直接 ssh 配置里的别名即可）'; return }
    Start-Tool 'up' '连接' $false
})

$ui.btnApply.Add_Click({
    $u = $ui.tSshUser.Text.Trim()
    if (-not $u) { [void][System.Windows.MessageBox]::Show('请填写 ZJU SSH 账户名', '提示'); return }
    $m = if ($ui.cmoMode.SelectedIndex -eq 1) { 'socks' } else { 'tun' }
    $v = $ui.tVpnUser.Text.Trim()
    $p = $ui.tVpnPass.Text
    $escQ = { param($s) ('"' + ($s -replace '"', '\"') + '"') }
    $hh = $ui.tSshHost.Text.Trim()
    if (-not $hh) { [void][System.Windows.Forms.MessageBox]::Show('请填写工作站地址（设置页第一行）', '提示'); return }
    $pp = $ui.tSshPort.Text.Trim(); if (-not $pp -match '^\d+$') { $pp = '22' }
    $aa = $ui.tAlias.Text.Trim();  if (-not $aa) { $aa = 'zju' }
    $zs = $ui.tZjuServer.Text.Trim(); if (-not $zs) { $zs = 'rvpn.zju.edu.cn:443' }
    $sv = ($zs -split ':')[0]
    $zp = if (($zs -split ':').Count -gt 1) { ($zs -split ':')[1] } else { '443' }
    # 密码经环境变量传递（不出现在子进程命令行里，避免本机其他进程读取）
    $env:ZJU_SSH_VPNPASS = $p
    # 子进程无控制台可交互：设此标记让 init 的 Read-Host 安全跳过（否则隐藏窗口里会永久挂起）
    $env:ZJU_SSH_NONINTERACTIVE = '1'
    # -NoDownload：保存只写配置、立即完成；zju-connect 下载放到首次“一键连接”时自动进行
    # 注：powershell -File 会丢弃空字符串参数，空值必须整体不传（-VpnUser 空=跳过校外通道）
    $argline = 'init -NoDownload -Mode ' + $m + ' -SshUser ' + (& $escQ $u)
    if ($v) { $argline += ' -VpnUser ' + (& $escQ $v) }
    $argline += ' -SshHost ' + (& $escQ $hh) + ' -SshPort ' + $pp + ' -HostAlias ' + (& $escQ $aa) `
        + ' -Server ' + (& $escQ $sv) + ' -ZjuPort ' + $zp
    Start-Tool $argline '保存配置' $false
})

$ui.btnDoctor.Add_Click({ Start-Tool 'doctor' '自检' $true })
$ui.btnDown.Add_Click({ Start-Tool 'down' '停止隧道' $false })

$ui.btnKey.Add_Click({
    $pub = Join-Path $env:USERPROFILE '.ssh\id_ed25519.pub'
    if (-not (Test-Path $pub)) {
        Append-Log '▶ 生成 ed25519 密钥（无口令）…'
        $sshKeygen = "$env:WINDIR\System32\OpenSSH\ssh-keygen.exe"
        & $sshKeygen -t ed25519 -N '""' -C "$env:USERNAME@zju" -f "$env:USERPROFILE\.ssh\id_ed25519" 2>&1 | ForEach-Object { Append-Log ([string]$_) }
    }
    if (Test-Path $pub) {
        $content = (Get-Content $pub -Raw).Trim()
        try { [System.Windows.Clipboard]::SetText($content); Append-Log '★ 公钥已复制到剪贴板，粘贴发给管理员即可开通：' }
        catch { Append-Log '公钥内容（手动复制）：' }
        Append-Log $content
    }
})

$ui.tglAuto.Add_Click({
    $m = if ($ui.cmoMode.SelectedIndex -eq 1) { 'socks' } else { 'tun' }
    if ($m -eq 'socks') {
        [void][System.Windows.MessageBox]::Show('SOCKS 模式暂不支持开机自启；校外时点“一键连接 ZJU”会自动拉起隧道。', '提示')
        $ui.tglAuto.IsChecked = $false
        return
    }
    if ($ui.tglAuto.IsChecked) { Start-Tool 'install-task' '注册开机自启' $false }
    else { Start-Tool 'uninstall-task' '移除开机自启' $false }
})

$ui.navHome.Add_Click({ Show-Page 'home' })
$ui.navSettings.Add_Click({ Show-Page 'settings' })

$ui.btnTheme.Add_Click({
    # 全新机器可能没有任何 config.json（$cfg 为 null），必须自建对象，否则赋值抛异常会带崩整个进程
    try {
        $newTheme = if ($script:theme -eq 'dark') { 'light' } else { 'dark' }
        $c = Get-ToolConfig -LocalPath $cfgLocal -ToolPath $cfgTool
        if (-not $c) { $c = New-Object psobject }
        $c | Add-Member -NotePropertyName theme -NotePropertyValue $newTheme -Force
        Save-ToolConfig -Cfg $c -Path $cfgLocal
    } catch {
        Append-Log ('主题保存失败（主题未切换）：' + $_.Exception.Message)
        return
    }
    # 重启窗口以应用主题（调色板在 XAML 加载前注入）
    Start-Process powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"' + (Join-Path $toolDir 'zju-ssh-gui.ps1') + '"')) -WorkingDirectory $toolDir
    $script:reallyExit = $true
    $notify.Visible = $false
    $window.Close()
})

$notify = New-Object System.Windows.Forms.NotifyIcon
$bmpIcon = New-Object System.Drawing.Bitmap 64, 64
$gI = [System.Drawing.Graphics]::FromImage($bmpIcon)
$gI.SmoothingMode = 'AntiAlias'
$gI.Clear([System.Drawing.Color]::Transparent)
$brushBlue = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(79, 140, 255))
$gI.FillEllipse($brushBlue, 3, 3, 58, 58)
$fontI = New-Object System.Drawing.Font('Arial', 28, [System.Drawing.FontStyle]::Bold)
$gI.DrawString('C', $fontI, [System.Drawing.Brushes]::White, 16, 10)
$notify.Icon = [System.Drawing.Icon]::FromHandle($bmpIcon.GetHicon())
$notify.Text = 'ZJU SSH 助手'
$notify.Visible = $false
$menuTray = New-Object System.Windows.Forms.ContextMenuStrip
$miShow = $menuTray.Items.Add('显示主界面')
$miExit = $menuTray.Items.Add('退出')
$notify.ContextMenuStrip = $menuTray
# 托盘恢复只置标志，不直接 Show()：窗口由外层 ShowDialog 循环重新显示。
# 若在此处 Show()，外层循环再调 ShowDialog() 会因窗口已可见而抛异常。
$script:restoreRequested = $false
$script:trayFrame = $null
$miShow.Add_Click({ $script:restoreRequested = $true; if ($script:trayFrame) { $script:trayFrame.Continue = $false } })
$miExit.Add_Click({ $script:reallyExit = $true; $notify.Visible = $false; if ($script:trayFrame) { $script:trayFrame.Continue = $false }; $window.Close() })
$notify.Add_DoubleClick({ $script:restoreRequested = $true; if ($script:trayFrame) { $script:trayFrame.Continue = $false } })
$window.Add_Closing({
    param($s, $e)
    if (-not $script:reallyExit) {
        $e.Cancel = $true
        $window.Hide()
        $notify.Visible = $true
    }
})

# 兜底：按钮处理器里的未捕获异常只记日志，不得带崩窗口（GUI 按钮只有实机点击才测得到，smoke 覆盖不了）
try {
    if (-not [System.Windows.Application]::Current) { $null = New-Object System.Windows.Application }
    [System.Windows.Application]::Current.add_DispatcherUnhandledException({
        param($s, $e)
        try { Append-Log ('■ 内部错误（已拦截）：' + $e.Exception.Message) } catch { }
        $e.Handled = $true
    })
} catch { }

# 计时器必须常开：状态自动刷新与 zju-connect 运行日志跟踪都挂在 tick 上（此前只在 Start-Tool 里启动，
# 导致 GUI 启动后状态与日志永不自动更新）
$timer.Start()
Update-StatusQuiet
# 窗口生命周期：Close 时 Cancel+Hide 会让 ShowDialog 返回（WPF 模态循环随窗口隐藏而结束），
# 但托盘常驻要求进程继续存活，故在 reallyExit 之前循环重入 ShowDialog。
# 若不循环，脚本会直接走到底退出，托盘图标随之消失——"关闭最小化到托盘"从未真正生效。
while (-not $script:reallyExit) {
    $script:restoreRequested = $false
    # ShowDialog 自身负责显示窗口（此处窗口必为 Hidden，直接 Show 后再 ShowDialog 会抛异常）
    [void]$window.ShowDialog()
    if ($script:reallyExit) { break }
    # ShowDialog 返回且非退出 = 刚隐藏到托盘。PushFrame 跑嵌套消息循环等待唤回，
    # 这样托盘菜单/双击事件才会被派发；Start-Sleep 轮询会阻塞消息泵使托盘失去响应。
    if (-not $script:restoreRequested) {
        $script:trayFrame = New-Object System.Windows.Threading.DispatcherFrame
        [System.Windows.Threading.Dispatcher]::PushFrame($script:trayFrame)
        $script:trayFrame = $null
    }
    if ($script:reallyExit) { break }
}
$notify.Visible = $false
