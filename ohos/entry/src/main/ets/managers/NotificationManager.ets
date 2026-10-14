import { common, wantAgent, WantAgent } from '@kit.AbilityKit'
import { backgroundTaskManager } from '@kit.BackgroundTasksKit'
import { commonEventManager } from '@kit.BasicServicesKit'
import { notificationManager } from '@kit.NotificationKit'
import { Lock } from '../utils/Lock'
import { globalState, RunState } from '../GlobalState'

const VPN_NOTIFICATION_ID = 10001

export interface VpnNotificationParams {
  phase: string
  title: string
  content: string
  configHint: string
  showActions: boolean
}

export default class NotificationManager {
  private context: common.UIAbilityContext
  private subscriber: commonEventManager.CommonEventSubscriber
  private unlock: (() => void) | undefined
  private latestParams: VpnNotificationParams | undefined
  private publishTimer: number | undefined
  private lastPublishMs: number = 0
  private readonly minPublishIntervalMs: number = 1500
  private openWantAgent: WantAgent | undefined
  private disconnectWantAgent: WantAgent | undefined
  private reswitchWantAgent: WantAgent | undefined
  private get lock(): Lock {
    if (!AppStorage.has('notification_lock')) AppStorage.setOrCreate('notification_lock', new Lock())
    return AppStorage.get('notification_lock') as Lock
  }

  constructor(context: common.UIAbilityContext) {
    this.context = context
    this.subscriber = commonEventManager.createSubscriberSync({
      events: ['SERVICE_START', 'SERVICE_STOP']
    } as commonEventManager.CommonEventSubscribeInfo)
  }

  applyParams(raw: string): void {
    try {
      this.latestParams = JSON.parse(raw) as VpnNotificationParams
      if (this.latestParams?.phase === 'disconnected') {
        this.clearNotification()
        return
      }
      this.schedulePublish(true)
    } catch (err) {
      console.log(`Notification params parse failed <= ${err}`)
    }
  }

  clearNotification(): void {
    this.latestParams = undefined
    if (this.publishTimer !== undefined) {
      clearTimeout(this.publishTimer)
      this.publishTimer = undefined
    }
    notificationManager.cancel(VPN_NOTIFICATION_ID, (err: Error) => {
      if (err) console.log(`Cancel notification failed <= ${err.message ?? err}`)
    })
  }

  subscribe(): Promise<void> {
    return this.lock.acquire(this.context.abilityInfo.name).then((unlock: () => void): Promise<void> => {
      this.unlock = unlock
      if (globalState.runState === RunState.start) {
        void this.startContinuousTask()
      }
      return commonEventManager.subscribeToEvent(this.subscriber, (commonEventData: commonEventManager.CommonEventData) => {
        if (commonEventData.event === 'SERVICE_START') {
          void this.startContinuousTask()
        } else if (commonEventData.event === 'SERVICE_STOP') {
          void this.stopContinuousTask()
          this.clearNotification()
        }
      }).catch((err: Error) => {
        if (this.unlock) {
          this.unlock()
          this.unlock = undefined
        }
        throw err
      })
    })
  }

  unsubscribe(): Promise<void> {
    commonEventManager.unsubscribe(this.subscriber)
    this.clearNotification()
    if (this.unlock) {
      this.unlock()
      this.unlock = undefined
    } else {
      this.lock.revoke(this.context.abilityInfo.name)
    }
    return Promise.resolve()
  }

  private schedulePublish(force: boolean): void {
    const now = Date.now()
    const elapsed = now - this.lastPublishMs
    const delay = force ? 0 : Math.max(0, this.minPublishIntervalMs - elapsed)
    if (this.publishTimer !== undefined) clearTimeout(this.publishTimer)
    this.publishTimer = setTimeout(() => {
      this.publishTimer = undefined
      this.publishNow()
    }, delay)
  }

  private publishNow(): Promise<void> {
    const params = this.latestParams
    if (!params || globalState.runState !== RunState.start) {
      return Promise.resolve()
    }
    return this.ensureWantAgents().then(() => {
      const request: notificationManager.NotificationRequest = {
        id: VPN_NOTIFICATION_ID,
        slotType: notificationManager.SlotType.SERVICE_INFORMATION,
        isOngoing: true,
        isUnremovable: true,
        tapDismissed: false,
        showDeliveryTime: false,
        wantAgent: this.openWantAgent,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: params.title,
            text: params.content,
            additionalText: params.configHint,
          },
        },
        actionButtons: params.showActions ? [
          {
            title: '断开',
            wantAgent: this.disconnectWantAgent,
          },
          {
            title: '切换线路',
            wantAgent: this.reswitchWantAgent,
          },
        ] : [],
      }
      return new Promise<void>((resolve) => {
        notificationManager.publish(request, (err: Error) => {
          if (err) {
            console.log(`Publish notification failed <= ${err.message ?? err}`)
          } else {
            this.lastPublishMs = Date.now()
          }
          resolve()
        })
      })
    })
  }

  private ensureWantAgents(): Promise<void> {
    if (this.openWantAgent && this.disconnectWantAgent && this.reswitchWantAgent) {
      return Promise.resolve()
    }
    const bundleName = this.context.applicationInfo.name
    const openInfo: wantAgent.WantAgentInfo = {
      wants: [{ bundleName, abilityName: 'EntryAbility' }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
    }
    const disconnectInfo: wantAgent.WantAgentInfo = {
      wants: [{
        bundleName,
        abilityName: 'EntryAbility',
        parameters: { harmonyNotificationAction: 'disconnect' },
      }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 1,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
    }
    const reswitchInfo: wantAgent.WantAgentInfo = {
      wants: [{
        bundleName,
        abilityName: 'EntryAbility',
        parameters: { harmonyNotificationAction: 'reswitch' },
      }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 2,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
    }
    return wantAgent.getWantAgent(openInfo).then((agent: WantAgent) => {
      this.openWantAgent = agent
      return wantAgent.getWantAgent(disconnectInfo)
    }).then((agent: WantAgent) => {
      this.disconnectWantAgent = agent
      return wantAgent.getWantAgent(reswitchInfo)
    }).then((agent: WantAgent) => {
      this.reswitchWantAgent = agent
    })
  }

  private startContinuousTask(): Promise<void> {
    const wantAgentInfo: wantAgent.WantAgentInfo = {
      wants: [{
        bundleName: this.context.applicationInfo.name,
        abilityName: 'EntryAbility',
      }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    }
    return wantAgent.getWantAgent(wantAgentInfo).then((wantAgentObj: WantAgent) => {
      backgroundTaskManager.on('continuousTaskCancel', () => { setTimeout(() => this.startContinuousTask(), 1000) })
      return backgroundTaskManager.startBackgroundRunning(
        this.context,
        backgroundTaskManager.BackgroundMode.TASK_KEEPING,
        wantAgentObj,
      )
    })
  }

  private stopContinuousTask(): Promise<void> {
    backgroundTaskManager.off('continuousTaskCancel')
    return backgroundTaskManager.stopBackgroundRunning(this.context)
  }
}
